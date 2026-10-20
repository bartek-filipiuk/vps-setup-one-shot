// Pure functions and the SQL each queue function sends, against a fake database (no Postgres,
// no pg package needed). The real database path is proven by test/fixtures.sh starter-worker.
import test from "node:test";
import assert from "node:assert/strict";
import { backoffMs, claim, complete, enqueue, fail, parsePayload, prune, requeueStale, stats, validKind } from "../src/queue.js";
import { HANDLERS, runJob } from "../src/jobs.js";
import { healthAnswer } from "../src/health.js";

// fakeDb ANSWERS -> {query, calls}: each query gets the next answer (an object, or an Error to throw).
function fakeDb(...answers) {
  const calls = [];
  return {
    calls,
    async query(text, values = []) {
      calls.push({ text: text.replace(/\s+/g, " ").trim(), values });
      const a = answers.length ? answers.shift() : { rows: [], rowCount: 0 };
      if (a instanceof Error) throw a;
      return a;
    },
  };
}
const quiet = { log() {}, error() {} };

test("validKind", () => {
  for (const k of ["echo", "send_mail", "report.daily", "a-b", "x1"]) assert.equal(validKind(k), true, k);
  for (const k of ["", "Echo", "1x", "a b", "a;b", "x".repeat(101), undefined, 3]) assert.equal(validKind(k), false, String(k));
});

test("parsePayload: objects only", () => {
  assert.deepEqual(parsePayload(undefined), {});
  assert.deepEqual(parsePayload("  "), {});
  assert.deepEqual(parsePayload('{"a":1,"b":[2]}'), { a: 1, b: [2] });
  assert.throws(() => parsePayload("{nope"), /not valid JSON/);
  assert.throws(() => parsePayload("[1]"), /must be a JSON object/);
  assert.throws(() => parsePayload("null"), /must be a JSON object/);
  assert.throws(() => parsePayload('"x"'), /must be a JSON object/);
  assert.throws(() => parsePayload(JSON.stringify({ a: "x".repeat(70000) })), /larger than 65536 bytes/);
});

test("backoffMs doubles from 10 s and stops at one hour", () => {
  assert.equal(backoffMs(1), 10000);
  assert.equal(backoffMs(2), 20000);
  assert.equal(backoffMs(3), 40000);
  assert.equal(backoffMs(9), 2560000);
  assert.equal(backoffMs(10), 3600000);
  assert.equal(backoffMs(1000), 3600000);
  assert.equal(backoffMs(0), 10000);
  assert.equal(backoffMs("x"), 10000);
});

test("enqueue: one insert with the payload as JSON; a bad kind sends nothing", async () => {
  const db = fakeDb({ rows: [{ id: "7" }], rowCount: 1 });
  assert.equal(await enqueue(db, "echo", { a: 1 }), "7");
  assert.match(db.calls[0].text, /^insert into jobs \(kind, payload, run_at, max_attempts\) values/);
  assert.deepEqual(db.calls[0].values, ["echo", '{"a":1}', null, 5]);
  const none = fakeDb();
  await assert.rejects(enqueue(none, "Bad Kind", {}), /not a job kind/);
  assert.equal(none.calls.length, 0);
});

test("claim: oldest due queued job with SKIP LOCKED; null when none", async () => {
  const job = { id: "1", kind: "echo", payload: {}, attempts: 1, max_attempts: 5 };
  const db = fakeDb({ rows: [job], rowCount: 1 }, { rows: [], rowCount: 0 });
  assert.deepEqual(await claim(db), job);
  assert.equal(await claim(db), null);
  const sql = db.calls[0].text;
  assert.match(sql, /status = 'running'/);
  assert.match(sql, /attempts = attempts \+ 1/);
  assert.match(sql, /where status = 'queued' and run_at <= now\(\) order by run_at, id for update skip locked limit 1/);
});

test("fail: backoff from the attempts, final flag, error text cut to 500", async () => {
  const db = fakeDb({ rows: [{ status: "queued" }], rowCount: 1 }, { rows: [{ status: "failed" }], rowCount: 1 });
  assert.equal(await fail(db, { id: "3", attempts: 2 }, "boom"), "queued");
  assert.deepEqual(db.calls[0].values, ["3", "boom", false, 20]);
  assert.equal(await fail(db, { id: "3", attempts: 1 }, "x".repeat(900), { final: true }), "failed");
  assert.equal(db.calls[1].values[1].length, 500);
  assert.equal(db.calls[1].values[2], true);
  assert.match(db.calls[0].text, /attempts >= max_attempts then 'failed' else 'queued'/);
});

test("complete and requeueStale", async () => {
  const db = fakeDb({ rowCount: 1 }, { rowCount: 2 });
  await complete(db, "9");
  assert.match(db.calls[0].text, /set status = 'done', finished_at = now\(\)/);
  assert.deepEqual(db.calls[0].values, ["9"]);
  assert.equal(await requeueStale(db, 900), 2);
  assert.match(db.calls[1].text, /where status = 'running' and locked_at < now\(\) - make_interval\(secs => \$1\)/);
  assert.deepEqual(db.calls[1].values, [900]);
});

test("prune deletes only done and failed jobs, and old cron slots", async () => {
  const db = fakeDb({ rowCount: 4 }, { rowCount: 2 });
  assert.deepEqual(await prune(db, 14), { jobs: 4, cronRuns: 2 });
  assert.match(db.calls[0].text, /^delete from jobs where status in \('done', 'failed'\) and coalesce\(finished_at, created_at\) < now\(\) - make_interval\(days => \$1\)$/);
  assert.match(db.calls[1].text, /^delete from cron_runs where due_at < now\(\) - make_interval\(days => \$1\)$/);
  const d = fakeDb();
  await prune(d, "nonsense");
  assert.deepEqual(d.calls[0].values, [14]);
  await prune(d, 0.5);
  assert.deepEqual(d.calls[2].values, [1]);
});

test("stats returns the rows", async () => {
  const rows = [{ status: "done", count: 3, oldest_seconds: 0 }, { status: "queued", count: 1, oldest_seconds: 12 }];
  assert.deepEqual(await stats(fakeDb({ rows })), rows);
});

test("runJob: done, retried, failed, unknown kind", async () => {
  const job = { id: "5", kind: "ok", payload: { a: 1 }, attempts: 1, max_attempts: 5 };
  let seen;
  const handlers = { ok: async (p) => { seen = p; }, bad: async () => { throw new Error("nope"); } };
  let db = fakeDb({ rowCount: 1 });
  assert.equal(await runJob(db, job, { handlers, log: quiet }), "done");
  assert.deepEqual(seen, { a: 1 });
  assert.match(db.calls[0].text, /status = 'done'/);
  db = fakeDb({ rows: [{ status: "queued" }], rowCount: 1 });
  assert.equal(await runJob(db, { ...job, kind: "bad" }, { handlers, log: quiet }), "queued");
  assert.deepEqual(db.calls[0].values.slice(1, 3), ["nope", false]);
  db = fakeDb({ rows: [{ status: "failed" }], rowCount: 1 });
  assert.equal(await runJob(db, { ...job, kind: "toString" }, { handlers, log: quiet }), "failed");
  assert.deepEqual(db.calls[0].values.slice(1, 3), ["no handler for job kind 'toString'", true]);
});

test("built-in handlers: echo and prune", async () => {
  assert.deepEqual(Object.keys(HANDLERS).sort(), ["echo", "prune"]);
  const db = fakeDb({ rowCount: 0 }, { rowCount: 0 });
  const orig = console.log; console.log = () => {};
  try {
    await HANDLERS.echo({ x: 1 }, { db, env: {} });
    await HANDLERS.prune({}, { db, env: { WORKER_PRUNE_DAYS: "30" } });
  } finally { console.log = orig; }
  assert.deepEqual(db.calls[0].values, [30]);
});

test("health: ok, database down, loop stuck; exactly two keys", async () => {
  const orig = console.error; console.error = () => {};
  try {
    const now = Date.now();
    let a = await healthAnswer(fakeDb({ rows: [] }), { lastTick: now }, 300000, now);
    assert.deepEqual(a, { code: 200, body: { status: "ok", db: "ok" } });
    assert.equal(fakeDb().calls.length, 0);
    a = await healthAnswer(fakeDb(new Error("connect ECONNREFUSED")), { lastTick: now }, 300000, now);
    assert.deepEqual(a, { code: 503, body: { status: "error", db: "error" } });
    a = await healthAnswer(fakeDb({ rows: [] }), { lastTick: now - 300001 }, 300000, now);
    assert.deepEqual(a, { code: 503, body: { status: "error", db: "ok" } });
  } finally { console.error = orig; }
});
