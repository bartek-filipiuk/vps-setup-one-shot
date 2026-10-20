// Job handlers: kind -> async (payload, ctx) => void. A handler that throws is retried with
// backoff (queue.fail); an unknown kind fails at once. Add a kind here, then enqueue it from the
// web app with one insert (README.md). Handlers must be safe to run twice: a container killed
// mid-job runs it again after the lock expires.
import { complete, fail, prune } from "./queue.js";

export const HANDLERS = {
  echo: async (payload) => {
    console.log(`echo: ${JSON.stringify(payload)}`);
  },
  prune: async (payload, { db, env }) => {
    const days = Number(payload.days ?? env.WORKER_PRUNE_DAYS ?? 14);
    const n = await prune(db, days);
    console.log(`prune: ${n.jobs} finished jobs and ${n.cronRuns} cron slots older than ${days} days deleted`);
  },
};

// runJob DB JOB -> runs the claimed JOB and records the result; returns "done", "queued" (a
// retry later), "failed", or "lost" when the lock expired meanwhile and another claim owns the
// row: the result is discarded and nothing is retried (the new owner decides).
export async function runJob(db, job, { handlers = HANDLERS, env = process.env, log = console } = {}) {
  const lost = () => { log.error(`job ${job.id} ${job.kind}: lock lost, result discarded`); return "lost"; };
  const handler = Object.hasOwn(handlers, job.kind) ? handlers[job.kind] : null;
  if (!handler) {
    if (!(await fail(db, job, `no handler for job kind '${job.kind}'`, { final: true }))) return lost();
    log.error(`job ${job.id} ${job.kind}: failed, no handler for this kind`);
    return "failed";
  }
  try {
    await handler(job.payload ?? {}, { db, env, job });
  } catch (err) {
    const status = await fail(db, job, err?.message ?? String(err));
    if (!status) return lost();
    log.error(`job ${job.id} ${job.kind}: attempt ${job.attempts}/${job.max_attempts} failed: ${err?.message ?? err}; ${status === "failed" ? "giving up" : "retried later"}`);
    return status;
  }
  if (!(await complete(db, job))) return lost();
  log.log(`job ${job.id} ${job.kind}: done`);
  return "done";
}
