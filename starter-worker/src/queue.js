// The job queue: one table, claimed with FOR UPDATE SKIP LOCKED, so two worker containers
// (a rolling deploy) never run the same job. A claim writes a fresh lock_token (a separate owner
// column, not locked_at): complete and fail only touch the row while it is still "running" with
// that token, and heartbeat moves locked_at forward under the same token. A job whose lock
// expired and was claimed again keeps the new owner's result; the old one is discarded. Every function takes the database (anything with
// pg's query(text, values)) as its first argument; nothing here opens a connection.

export const KIND_RE = /^[a-z][a-z0-9_.-]{0,99}$/;
export const MAX_PAYLOAD_BYTES = 65536;
const MAX_ERROR_CHARS = 500;

// validKind KIND -> true for a job kind: lower-case letters, digits, _ . -, at most 100.
export function validKind(kind) {
  return typeof kind === "string" && KIND_RE.test(kind);
}

// parsePayload TEXT -> the JSON object in TEXT ({} for empty); throws for anything else.
export function parsePayload(text) {
  if (text === undefined || text.trim() === "") return {};
  if (Buffer.byteLength(text) > MAX_PAYLOAD_BYTES) throw new Error(`payload is larger than ${MAX_PAYLOAD_BYTES} bytes`);
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    throw new Error("payload is not valid JSON");
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("payload must be a JSON object");
  return value;
}

// backoffMs ATTEMPTS -> the wait before the next try: 10 s, 20 s, 40 s, ... at most one hour.
export function backoffMs(attempts) {
  const n = Math.max(1, Math.min(Number(attempts) || 1, 30));
  return Math.min(2 ** n * 5000, 3600 * 1000);
}

export async function enqueue(db, kind, payload = {}, { runAt = null, maxAttempts = 5 } = {}) {
  if (!validKind(kind)) throw new Error(`not a job kind: '${kind}'`);
  const r = await db.query(
    "insert into jobs (kind, payload, run_at, max_attempts) values ($1, $2::jsonb, coalesce($3::timestamptz, now()), $4) returning id",
    [kind, JSON.stringify(payload), runAt, maxAttempts],
  );
  return r.rows[0].id;
}

// claim -> the oldest due job, now "running" with a new lock_token, or null when nothing is due.
export async function claim(db) {
  const r = await db.query(`
    update jobs set status = 'running', locked_at = now(), lock_token = gen_random_uuid(), attempts = attempts + 1
    where id = (select id from jobs where status = 'queued' and run_at <= now()
                order by run_at, id for update skip locked limit 1)
    returning id, kind, payload, attempts, max_attempts, lock_token`);
  return r.rows[0] ?? null;
}

// heartbeat JOB -> moves locked_at to now while JOB runs, so a long job is not taken for a dead
// one; false when the lock is lost.
export async function heartbeat(db, job) {
  const r = await db.query(
    "update jobs set locked_at = now() where id = $1 and status = 'running' and lock_token = $2",
    [job.id, job.lock_token],
  );
  return (r.rowCount ?? 0) > 0;
}

// complete JOB -> "done"; false when the lock is lost (nothing changed).
export async function complete(db, job) {
  const r = await db.query(
    `update jobs set status = 'done', finished_at = now(), locked_at = null, lock_token = null, last_error = null
     where id = $1 and status = 'running' and lock_token = $2`,
    [job.id, job.lock_token],
  );
  return (r.rowCount ?? 0) > 0;
}

// fail -> back to "queued" after backoffMs(attempts), or "failed" once max_attempts is reached
// (at once with final). Returns the new status, or null when the lock is lost (nothing changed).
export async function fail(db, job, message, { final = false } = {}) {
  const r = await db.query(
    `update jobs set locked_at = null, lock_token = null, last_error = $2,
       status = case when $3 or attempts >= max_attempts then 'failed' else 'queued' end,
       finished_at = case when $3 or attempts >= max_attempts then now() end,
       run_at = case when $3 or attempts >= max_attempts then run_at else now() + make_interval(secs => $4) end
     where id = $1 and status = 'running' and lock_token = $5 returning status`,
    [job.id, String(message).slice(0, MAX_ERROR_CHARS), final, backoffMs(job.attempts) / 1000, job.lock_token],
  );
  return r.rows[0]?.status ?? null;
}

// requeueStale SECONDS -> jobs left "running" longer than SECONDS (a container killed mid-job)
// go back to the queue, or to "failed" when their attempts are used up. Returns how many.
export async function requeueStale(db, seconds) {
  const r = await db.query(
    `update jobs set locked_at = null, lock_token = null, last_error = 'lock expired: the worker stopped while running it',
       status = case when attempts >= max_attempts then 'failed' else 'queued' end,
       finished_at = case when attempts >= max_attempts then now() end
     where status = 'running' and locked_at < now() - make_interval(secs => $1)`,
    [seconds],
  );
  return r.rowCount ?? 0;
}

// prune DAYS -> deletes finished jobs ("done" and "failed" only) and cron slots older than DAYS.
export async function prune(db, days) {
  const d = Math.max(1, Math.floor(Number(days) || 14));
  const jobs = await db.query(
    "delete from jobs where status in ('done', 'failed') and coalesce(finished_at, created_at) < now() - make_interval(days => $1)",
    [d],
  );
  const runs = await db.query("delete from cron_runs where due_at < now() - make_interval(days => $1)", [d]);
  return { jobs: jobs.rowCount ?? 0, cronRuns: runs.rowCount ?? 0 };
}

// stats -> [{status, count, oldest_seconds}]: how many jobs per status, and for "queued" how
// long the oldest due one has been waiting.
export async function stats(db) {
  const r = await db.query(`
    select status, count(*)::int as count,
      coalesce(extract(epoch from now() - min(run_at) filter (where status = 'queued' and run_at <= now())), 0)::int as oldest_seconds
    from jobs group by status order by status`);
  return r.rows;
}
