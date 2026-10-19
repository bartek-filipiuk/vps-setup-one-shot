# Uptime Kuma 2.x: what this guide uses (R06b)

`UPTIME.md`, `kuma.js` and the `kuma_*` helpers in `lib.sh`. Kuma runs as the Coolify one-click
service `uptime-kuma` (`SERVICES.md`; the template is in `references/coolify-api.md`).

**Status:** written from the Uptime Kuma 2.0 source (server socket handlers, the setup-database
server, `EditMonitor.vue`, the status page router) and tested against a fake Kuma only
(`test/kuma.test.js`: a fake socket.io client and a fake fetch; `test/lib.test.sh` and
`test/status.test.sh`: a fake docker that answers for `kuma.js`, and the public JSON from a fake
HTTP server). **Not run against a real Kuma yet.** Every line below is **[verify]** until the
first run on a throwaway server; the list at the end is what that run must prove. The version
the template pulls (`louislam/uptime-kuma:2`) was 2.5.6 on 2026-10-09; the run records the one
it got.

## How it is driven

Kuma 2.x has no REST API for writes. API keys exist only for `/metrics`. The UI talks socket.io,
so `kuma.js` does too, with the `socket.io-client` (about 4.8) that ships in the image under
`/app/node_modules`, and Node's global `fetch`. `kuma_run` sends the script and a JSON plan
over the ssh stdin into a private temp directory on the server and runs
`docker exec -i <container> node -e "<script>" < plan.json`; the script talks to
`http://127.0.0.1:3001` inside the container, so it works before DNS and HTTPS. The plan carries
the admin password and only ever travels on stdin; the script text (no secret) is visible in
`ps` on the server while it runs.

Rejected: the Python `uptime-kuma-api` (1.x only), a script on the user's machine (needs Node
and the HTTPS domain), a REST wrapper container (one more thing to run), the 1.x JSON backup
import (gone in 2.x), a checklist in the UI only (cannot be tested; it stays the fallback in
`UPTIME.md` step 8).

## First start (a fresh volume)

Without `UPTIME_KUMA_DB_TYPE` (the template sets none) a fresh 2.x first serves a database-type
page, then the main server with a "create admin" page. Both are public: whoever is first owns
the monitor. `kuma_init` takes both right after the container runs.

| Call | Answer | Used by |
|------|--------|---------|
| `GET /setup-database-info` | `{runningSetup, needSetup, isEnabledEmbeddedMariaDB}` while the setup server runs; the main server answers something that is not this JSON (`kuma.js` reads that as "set up") | `kuma.js` init |
| `POST /setup-database {dbConfig: {type: "sqlite"}}` | `{ok: true}`, then the main server starts in the same process on the same port | `kuma.js` init |
| socket `needSetup(cb)` | `true` while there is no user | `kuma.js` init |
| socket `setup(username, password, cb)` | `{ok, msg}`; refused once a user exists; a password rated "Too weak" is refused (`kuma_env_init` makes 32 random base64 characters) | `kuma.js` init |

## Socket events after the login

| Event | Answer | Notes |
|-------|--------|-------|
| `login({username, password, token}, cb)` | `{ok: true, token}`, `{tokenRequired: true}` with 2FA on, `{ok: false, msg: "authIncorrectCreds"}` | then the server pushes `monitorList` (an object keyed by monitor id), `statusPageList` and `notificationList`; `kuma.js` waits up to 15 s for `monitorList` |
| `add(monitor, cb)` | `{ok, msg, monitorID}` | `kuma.js` sends the UI's defaults for an HTTP monitor (`MONITOR_DEFAULTS`: `type: "http"`, `method: "GET"`, `accepted_statuscodes: ["200-299"]`, `maxredirects: 10`, ...) with `interval: 60`, `retryInterval: 30`, `maxretries: 1`, `timeout: 30`; the 2.x-only fields (`conditions`, `kafkaProducer*`, `rabbitmqNodes`) as empty values |
| `getStatusPage(slug, cb)` | `{ok: true, config}`; `{ok: false, msg}` for an unknown slug | `config` holds `slug, title, description, icon, theme, showTags, domainNameList, customCSS, footerText, showPoweredBy, showCertificateExpiry, autoRefreshInterval` and the analytics fields |
| `addStatusPage(title, slug, cb)` | `{ok, msg}` | slug `^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$`; `lib.sh` allows lower case only |
| `saveStatusPage(slug, config, imgDataUrl, publicGroupList, cb)` | `{ok, publicGroupList}` | **every group missing from `publicGroupList` is deleted**, so `kuma.js` reads the groups first and sends all of them back; groups are `[{id?, name, monitorList: [{id, sendUrl?}]}]`, ordered by position. `imgDataUrl` is the current icon URL (`config.icon`, else `/icon.svg`), as the UI sends it; `published` is commented out in 2.0, so a page is public |
| `editMonitor`, `deleteMonitor`, `deleteStatusPage` | | never sent: `kuma.js` adds and merges only |

`kuma.js` matches a wanted monitor to an existing one by URL (lower case, trailing slash
ignored), whatever its name or whether it is paused, so a second run adds nothing.

## Public HTTP (no login)

| Call | Answer | Used by |
|------|--------|---------|
| `GET /status/<slug>` | the status page (HTML) | the user |
| `GET /api/status-page/<slug>` | `{config, incident, publicGroupList: [{id, name, weight, monitorList: [{id, name, sendUrl, url?, type}]}], maintenanceList}`; 404 for an unknown slug | `kuma.js` sync (the groups before a save), `kuma_status` |
| `GET /api/status-page/heartbeat/<slug>` | `{heartbeatList: {"<id>": [{status, time, msg, ping}, ...]}, uptimeList: {"<id>_24": 0.998}}`; `status` 0 down, 1 up, 2 pending, 3 maintenance; `time` like `2026-10-19 10:00:00.000` (UTC) | `kuma_status`, `status.sh` |
| `/api/badge/<id>/...`, `/api/push/<token>` | badges, push monitors | not used |

A host in `domainNameList` serves its page at `/` (R22 builds on it); this guide uses
`/status/<slug>` only and keeps the list as it is on every save.

## What the first run must prove

1. The container is `uptime-kuma-<service uuid>` (the pattern was seen with Umami on 4.3.23,
   2026-10-19; no Kuma service seen yet).
2. `node -e` in the container finds `socket.io-client` (cwd `/app`, or the `/app/node_modules`
   fallback) and Node has `fetch`; the websocket from 127.0.0.1 passes Kuma's origin check.
3. On a fresh volume `needSetup` is true, `POST /setup-database` with SQLite works and the main
   server answers within 60 seconds.
4. `setup` accepts the generated password, `login` returns a token and `monitorList` arrives.
5. `add` is accepted on the image the template pulls (record the version), and the monitor goes
   up through Traefik.
6. `addStatusPage` and `saveStatusPage` keep a group made by hand, `/status/<slug>` is public
   without a login, and the heartbeat JSON has the shape above.
7. The done criterion: the starter app stopped, its monitor down within about two minutes, the
   page shows it, the app started, up again (`UPTIME.md` step 6).
8. `extra/healthcheck` makes the service `running:healthy`; the `kuma.env` password logs in in the
   browser.
9. `npm run reset-password` in the container (`UPTIME.md` step 3) works and how it asks.
10. The `status.sh` Uptime section gives no false WARN on a clean setup.
