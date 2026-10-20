// Enqueue a job or print the queue, from inside the worker container (it has DATABASE_URL):
//   node enqueue.js <kind> [json]   the payload as an argument (no secrets: argv is visible)
//   node enqueue.js <kind> -        the payload from stdin
//   node enqueue.js stats           status, count, seconds the oldest due queued job waits
// Exit 0 on success, 1 on a bad kind or payload or a database error, 2 on wrong usage.
import { readFileSync } from "node:fs";
import { pool } from "./src/db.js";
import { enqueue, parsePayload, stats, validKind } from "./src/queue.js";
import { HANDLERS } from "./src/jobs.js";

const [kind, arg, extra] = process.argv.slice(2);
if (!kind || extra !== undefined) {
  console.error("usage: node enqueue.js <kind> [json|-]  |  node enqueue.js stats");
  process.exit(2);
}

let code = 0;
try {
  if (kind === "stats" && arg === undefined) {
    const rows = await stats(pool);
    if (!rows.length) console.log("no jobs");
    for (const r of rows) console.log(`${r.status} ${r.count} ${r.oldest_seconds}`);
  } else {
    if (!validKind(kind)) throw new Error(`not a job kind: '${kind}'`);
    if (!Object.hasOwn(HANDLERS, kind)) throw new Error(`unknown job kind '${kind}' (known: ${Object.keys(HANDLERS).join(", ")})`);
    const payload = parsePayload(arg === "-" ? readFileSync(0, "utf8") : arg);
    const id = await enqueue(pool, kind, payload);
    console.log(`enqueued job ${id} ${kind}`);
  }
} catch (err) {
  console.error(`enqueue: ${err.message}`);
  code = 1;
}
await pool.end().catch(() => {});
process.exit(code);
