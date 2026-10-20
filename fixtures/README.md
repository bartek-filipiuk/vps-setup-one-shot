# Fixtures

A fixture is the smallest app of one stack that follows the same contract as `starter/`: a
Dockerfile (or a compose file), a non-root user, a `PORT` from the environment, listening on IPv4
and IPv6 (Coolify's health check calls `localhost`), and a health route. `PREPARE-APP.md` uses
them as the model for an app of that stack. A stack without a green fixture is "not supported
yet".

| Stack | Directory | Port | Database | Coolify build pack | Status |
| --- | --- | --- | --- | --- | --- |
| Static site (nginx) | `static/` | 8080 | none | `dockerfile` | built and health-checked in CI; not deployed on a server yet |
| Python (FastAPI) | `python-fastapi/` | 8000 | Coolify Postgres via `DATABASE_URL` | `dockerfile` | built and health-checked in CI; not deployed on a server yet |
| Go (net/http) | `go/` | 8080 | Coolify Postgres via `DATABASE_URL` | `dockerfile` | built and health-checked in CI; not deployed on a server yet |
| Docker Compose (Go web + Postgres) | `compose/` | 8080 (web) | its own `db` service | `dockercompose` [verify] | built and health-checked in CI; not deployed on a server yet; no Coolify path in the runbooks yet |

Django, PHP, Ruby and anything else: no fixture, so not supported yet.

Health contract, the same as the starter's: `GET /api/health` answers `200`
`{"status":"ok","db":"ok"}` when the app and its database work (`"db":"none"` for an app without
a database), and `503` `{"status":"error","db":"error"}` otherwise, with no error details. The
check reads the schema (`select 1 from hits limit 1`), not just a connection. Apps with a
database create their table at start, retry while the database boots, and exit if it never
comes up, like `starter/lib/db.ts`.

The compose stack keeps its data in its own volume: it is outside Coolify's database backups and
outside the dump `deploy_and_wait` takes before a deploy.

Proof, with Docker and a recent compose v2 (`up --wait --wait-timeout`) on your machine (no
server): `bash test/fixtures.sh` builds all four and prints `ALL FIXTURES OK`;
`bash test/fixtures.sh go` runs one. It checks the answer on `127.0.0.1` and on `[::1]` inside
the container, the image's `HEALTHCHECK`, the non-root user, and `503` once the database is
stopped. On exit it removes the containers, images, networks and volumes it created, by name;
pulled base images and the build cache stay, and nothing is pruned. CI runs it per fixture
(`.github/workflows/fixtures.yml`).

The worker of `WORKER.md` (`starter-worker/`, Node 22 with `pg`) is built and checked by the
same script (`bash test/fixtures.sh starter-worker`): the health contract above, then a job
enqueued with `enqueue.js` (as an argument and on stdin) runs, both cron slots are claimed, an
unknown kind and a payload that is not an object are refused. Its two keys read: `db` is the
database (`select 1 from jobs limit 1`), `status` also says whether the job loop is alive, so
`503 {"status":"error","db":"ok"}` is a stuck loop with a working database. It has no domain;
only Coolify's and Docker's checks call it.

The sign-in app of `AUTH.md` (`starter-auth/`, the starter's Dockerfile with Next.js 16, `pg`
and `nodemailer`) is checked by the same script too (`bash test/fixtures.sh starter-auth`): the
health contract above (`select 1 from users limit 1`), then a whole sign-in against the real
Postgres with `MAIL_LOG=1`, so the mail is read from the container's log and nothing is sent:
the request, the link in the mail, the confirm page (opening it uses nothing), the confirm post,
the session cookie (`HttpOnly`, `SameSite=Lax`, no `Secure` on the test's http address), the
protected page with and without it, the link refused a second time, posts from another site and
without an `Origin` refused (403), five mails for six requests from one address, sign-out. Its
image has no `HEALTHCHECK`, like the starter's (the Dockerfile is the same file); the script
skips those two checks for it only, and Coolify's own health check calls `/api/health`.

Lockfiles are generated, never written by hand: `go.sum` by `go mod tidy` (golang:1.25-alpine),
`python-fastapi/requirements.txt` by `pip-compile --generate-hashes` from `requirements.in`
(python:3.12-slim), installed with `--require-hashes`, `starter-worker/package-lock.json` by
`npm install`, installed with `npm ci --omit=dev`, `starter-auth/package-lock.json` by `npm
install` (the starter's lockfile plus `nodemailer`), installed with `npm ci`.
