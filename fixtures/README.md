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

Proof, with Docker and compose v2.1+ on your machine (no server): `bash test/fixtures.sh` builds
all four and prints `ALL FIXTURES OK`; `bash test/fixtures.sh go` runs one. It checks the answer
on `127.0.0.1` and on `[::1]` inside the container, the image's `HEALTHCHECK`, the non-root user,
and `503` once the database is stopped. It removes everything it created by name. CI runs it per
fixture (`.github/workflows/fixtures.yml`).

Lockfiles are generated, never written by hand: `go.sum` by `go mod tidy` (golang:1.25-alpine),
`python-fastapi/requirements.txt` by `pip-compile` from `requirements.in` (python:3.12-slim).
