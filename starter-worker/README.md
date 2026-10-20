# Worker: cron and a job queue next to the web app

A second Coolify app from the same repo as the web app: built from this directory (Coolify's
base directory), no domain, the same Postgres. The web app puts jobs into a table; the worker
runs them, and it runs the schedules in `src/cron.js`. Set up with `WORKER.md` of
vps-setup-one-shot. Plain Node 22, one dependency (`pg`), no build step.

## What runs

- `src/main.js`: creates its two tables at start (`jobs`, `cron_runs`; retries while the
  database boots, then exits so the container restarts), serves `/api/health` on `PORT` (3000),
  then loops: this tick's cron slots, jobs whose container died put back, every due job, a pause
  of `WORKER_POLL_MS` (2000). `SIGTERM` (a deploy or a stop) lets the running job finish.
- `src/jobs.js`: the job kinds. `echo` logs its payload; `prune` deletes `done` and `failed`
  jobs older than `WORKER_PRUNE_DAYS` (14) and old cron slots. Nothing else is ever deleted.
- `src/cron.js`: the schedules. `heartbeat` (an `echo` every 5 minutes) and `prune` (daily at
  00:00 UTC). Each slot is claimed with an insert into `cron_runs`; only the container whose
  insert wins enqueues the job, so a slot runs once even with two containers alive during a
  deploy. Intervals only ("every N seconds", at least 60), no cron expressions.
- `src/queue.js`: the SQL. A job is claimed with `FOR UPDATE SKIP LOCKED`; a failure goes back
  to the queue after 10 s, 20 s, 40 s, ... (at most an hour) until `max_attempts` (5), then it
  is `failed` with `last_error`. A job left `running` for `WORKER_LOCK_SECONDS` (900; its
  container was killed) goes back to the queue, so handlers must be safe to run twice.
- Ownership: a claim writes a new `lock_token` (its own column; `locked_at` is only the time).
  While a handler runs, the worker renews `locked_at` every 30 s under that token and counts the
  loop as alive. `done` or a retry is written only while the row is still `running` with the
  token; if the lock expired and another claim took the job, the old result is logged as "lock
  lost, result discarded" and dropped.
- Stopping: on `SIGTERM` the running job may finish, but only within Coolify's stop grace
  period (30 s by default in the 4.3.23 source; the app's **Advanced** settings, or
  `stop_grace_period` through the API, 1 to 3600 s; not seen on a server [verify]). Docker kills
  the container after it, and a job killed there runs again once `WORKER_LOCK_SECONDS` expire:
  keep jobs shorter than the grace period, and idempotent.

## Enqueue from the web app

One insert, in the web app's own code, on its own connection (the same `DATABASE_URL`). The web
app never runs jobs itself:

```sql
insert into jobs (kind, payload) values ($1, $2::jsonb);
-- later: insert into jobs (kind, payload, run_at) values ($1, $2::jsonb, now() + interval '1 hour');
```

With `pg` in a Next.js route or server action: `await pool.query("insert into jobs (kind,
payload) values ($1, $2::jsonb)", ["echo", JSON.stringify({ hello: 1 })])`. The `jobs` table
exists once the worker started once; until then the insert fails. No secrets in a payload: it is
stored as plain JSON in the database and its backups.

From the worker container itself (`docker exec`, or `worker_enqueue` in vps-setup-one-shot):
`node enqueue.js echo '{"hello":1}'`, `node enqueue.js echo -` (payload on stdin),
`node enqueue.js stats` (`status count seconds-the-oldest-due-job-waits` per line).

## Add a job kind or a schedule

1. A handler in `HANDLERS` in `src/jobs.js`: `async (payload, { db, env, job }) => { ... }`.
   Throw to retry. Keep it idempotent.
2. A schedule, if it should run by itself: one entry in `SCHEDULES` in `src/cron.js`
   (`{ name, everySeconds, kind, payload }`). `npm test` checks that every schedule has a handler.
3. Push: Coolify rebuilds the worker (and the web app, same repo and branch).

## Health

`GET /api/health`, the contract of the web app: `200 {"status":"ok","db":"ok"}`; `503
{"status":"error","db":"error"}` when the database does not answer; `503
{"status":"error","db":"ok"}` when the database is fine but the loop has not ticked for
`WORKER_STALE_SECONDS` (300; a running handler keeps it alive through the 30-second renewal, so
this means the loop itself is stuck). The image's `HEALTHCHECK` calls it; nothing outside the
server can.

## One instance

The worker is meant to run as one container. A second one (a rolling deploy, or more on
purpose) is safe: jobs are claimed with `SKIP LOCKED` and each cron slot is enqueued once.

## Local run

`npm ci`, a Postgres (`docker run -d --name worker-db -e POSTGRES_PASSWORD=dev -p 5432:5432
postgres:17-alpine`), then `DATABASE_URL=postgres://postgres:dev@localhost:5432/postgres npm
start`. `npm test` runs the unit tests (no database).
