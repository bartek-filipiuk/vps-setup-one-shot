// The worker: schema at start, a health route on PORT, then the loop: claim this tick's cron
// slots, put back jobs whose container died, run every due job, sleep WORKER_POLL_MS.
// SIGTERM (a deploy, a stop) lets the running job finish, then exits 0.
import { pool, migrateOrExit } from "./db.js";
import { tick, SCHEDULES, validateSchedules } from "./cron.js";
import { claim, requeueStale } from "./queue.js";
import { HANDLERS, runJob } from "./jobs.js";
import { createHealthServer } from "./health.js";

function intEnv(name, fallback, min) {
  const v = Number(process.env[name] ?? fallback);
  return Number.isInteger(v) && v >= min ? v : fallback;
}

const PORT = intEnv("PORT", 3000, 1);
const POLL_MS = intEnv("WORKER_POLL_MS", 2000, 100);
const LOCK_SECONDS = intEnv("WORKER_LOCK_SECONDS", 900, 60);
const STALE_MS = intEnv("WORKER_STALE_SECONDS", 300, 10) * 1000;

validateSchedules(SCHEDULES, Object.keys(HANDLERS));

const state = { lastTick: Date.now(), stopping: false };
let wake = null;

function stop(signal) {
  if (state.stopping) return;
  console.log(`worker: ${signal}, finishing the current job`);
  state.stopping = true;
  if (wake) wake();
}
process.on("SIGTERM", () => stop("SIGTERM"));
process.on("SIGINT", () => stop("SIGINT"));

function sleep(ms) {
  return new Promise((resolve) => {
    const t = setTimeout(resolve, ms);
    wake = () => { clearTimeout(t); resolve(); };
  });
}

await migrateOrExit();
const server = createHealthServer(pool, state, STALE_MS);
// No host: Node listens on :: (IPv4 and IPv6) when the container has IPv6, else on 0.0.0.0.
// Coolify's health check calls localhost, which is ::1 first in Alpine.
server.listen(PORT, () => console.log(`worker: health on :${PORT}/api/health, poll ${POLL_MS} ms, schedules ${SCHEDULES.map((s) => s.name).join(", ")}`));

while (!state.stopping) {
  state.lastTick = Date.now();
  try {
    const fired = await tick(pool, new Date());
    if (fired.length) console.log(`cron: enqueued ${fired.join(", ")}`);
    const back = await requeueStale(pool, LOCK_SECONDS);
    if (back) console.log(`worker: ${back} jobs with an expired lock put back`);
    let job;
    while (!state.stopping && (job = await claim(pool))) {
      await runJob(pool, job);
      state.lastTick = Date.now();
    }
  } catch (err) {
    console.error(`worker: loop error: ${err.message}`);
  }
  if (!state.stopping) await sleep(POLL_MS);
}

server.close();
await pool.end().catch(() => {});
console.log("worker: stopped");
process.exit(0);
