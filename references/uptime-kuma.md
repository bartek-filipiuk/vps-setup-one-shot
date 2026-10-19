# Uptime Kuma 2.x: what this guide uses (R06b, R22)

`UPTIME.md`, `kuma.js` and the `kuma_*` helpers in `lib.sh`. Kuma runs as the Coolify one-click
service `uptime-kuma` (`SERVICES.md`; the template is in `references/coolify-api.md`).

**Status:** written from Uptime Kuma 2.x (2.5.6 source: server socket handlers, the setup-database
server, `EditMonitor.vue`, the status page router) and tested against a fake Kuma only
(`test/kuma.test.js`: a fake socket.io client and a fake fetch; `test/lib.test.sh` and
`test/status.test.sh`: a fake docker that answers for `kuma.js`, and the public JSON from a fake
HTTP server). **Not run against a real Kuma yet.** Every line below is **[verify]** until the
first run on a throwaway server; the list at the end is what that run must prove. The version
the template pulls (`louislam/uptime-kuma:2`) was 2.5.6 on 2026-10-09; the run records the one
it got. Kuma's master branch (the next major) moves to Better Auth and requires Node >= 24, which
breaks `kuma.js` (login and setup change); that is why the version is recorded at the first run.

`kuma.js` gives up after 90 seconds plus 20 per monitor it adds (each `add` waits up to 20 s),
at most 300 seconds.

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
| `login({username, password, token}, cb)` | `{ok: true, token}`, `{tokenRequired: true}` with 2FA on, `{ok: false, msg: "authIncorrectCreds"}` | then the server pushes `monitorList` (an object keyed by monitor id), `statusPageList` (an object keyed by page id, one `toJSON()` per page with `slug` and `domainNameList`, from `sendStatusPageList`) and `notificationList`; `kuma.js` waits up to 15 s for `monitorList` (sync) or `statusPageList` (domain) |
| `add(monitor, cb)` | `{ok, msg, monitorID}` | `kuma.js` sends the UI's defaults for an HTTP monitor (`MONITOR_DEFAULTS`: `type: "http"`, `method: "GET"`, `accepted_statuscodes: ["200-299"]`, `maxredirects: 10`, ...) with `interval: 60`, `retryInterval: 30`, `maxretries: 1`, `timeout: 30`; the 2.x-only fields (`conditions`, `kafkaProducer*`, `rabbitmqNodes`) as empty values |
| `getStatusPage(slug, cb)` | `{ok: true, config}`; `{ok: false, msg}` for an unknown slug | `config` holds `slug, title, description, icon, theme, showTags, domainNameList, customCSS, footerText, showPoweredBy, showCertificateExpiry, autoRefreshInterval` and the analytics fields |
| `addStatusPage(title, slug, cb)` | `{ok, msg}` | slug `^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$`; `lib.sh` allows lower case only |
| `saveStatusPage(slug, config, imgDataUrl, publicGroupList, cb)` | `{ok, publicGroupList}` | **every group missing from `publicGroupList` is deleted**, so `kuma.js` reads the groups first and sends all of them back (on a page this run just created there are none, and the public JSON is not read, see the cache below); groups are `[{id?, name, monitorList: [{id, sendUrl?, url?}]}]`, ordered by position. `url` is written to the monitor's custom link on the page, so `kuma.js` sends it back as it got it. `imgDataUrl` is the current icon URL (`config.icon`, else `/icon.svg`), as the UI sends it; `published` is commented out in 2.x, so a page is public |
| `editMonitor`, `deleteMonitor`, `deleteStatusPage` | | never sent: `kuma.js` adds and merges only (the domain action changes `domainNameList` only) |

`kuma.js` matches a wanted monitor to an existing one by URL (lower case, trailing slash
ignored), whatever its name or whether it is paused, so a second run adds nothing.

## Public HTTP (no login)

| Call | Answer | Used by |
|------|--------|---------|
| `GET /status/<slug>` | the status page (HTML) | the user |
| `GET /api/status-page/<slug>` | `{config, incidents, publicGroupList: [{id, name, weight, monitorList: [{id, name, sendUrl, url?, type}]}], maintenanceList}`; 404 for an unknown slug | `kuma.js` sync (the groups before a save), `kuma_status` |
| `GET /api/status-page/heartbeat/<slug>` | `{heartbeatList: {"<id>": [{status, time, msg, ping}, ...]}, uptimeList: {"<id>_24": 0.998}}`; `status` 0 down, 1 up, 2 pending, 3 maintenance; `time` like `2026-10-19 10:00:00.000` (UTC); `msg` is always `""` (`Heartbeat.toPublicJSON()` blanks it), so why a monitor is down is only on its page in Kuma | `kuma_status`, `status.sh` |
| `/api/badge/<id>/...`, `/api/push/<token>` | badges, push monitors | not used |

Both public answers are cached by Kuma: the page JSON for 5 minutes (a 404 too; `addStatusPage`
does not clear it), the heartbeats for 1 minute. So `kuma_status` and `status.sh` lag behind
Kuma by up to that, most visibly right after the first `kuma_sync`, and `kuma.js` does not read
the groups of a page it has just created (they are empty, and the cache may still hold a 404).

`kuma_sync` keeps `domainNameList` as it is on every save, so it never drops a client domain;
only the domain action below changes it.

## A page on its own domain (R22)

`UPTIME.md` step 9, the `kuma.js` domain action, `kuma_domain_add` and `kuma_domain_remove`.
From the 2.5.6 source; **[verify]** like the rest.

- **Stored by `saveStatusPage`.** After the login check it trims and lowercases the slug, copies
  the config fields (title, description, icon from `config.logo`, theme, showTags, footerText,
  customCSS, showPoweredBy, showCertificateExpiry, autoRefreshInterval, the analytics fields,
  ...), then `statusPage.updateDomainNameList(config.domainNameList)` and
  `StatusPage.loadDomainMappingList()`, then the groups (every group missing from the list is
  deleted, see above), then `apicache.clear()`. On any error the answer is `{ok: false, msg}`.
- **`updateDomainNameList` (`server/model/status_page.js`).** Not an array: `Invalid array`. In a
  transaction it deletes every domain of the page, then for each entry: not a string is
  `Invalid domain`, empty after trim is skipped, and **`DELETE FROM status_page_cname WHERE
  domain = ?`** before the insert. So a domain that sits on another page is moved to this one
  without a word, nothing is lowercased or checked, and the page keeps only the list it got.
  Hence `kuma.js`: hosts normalised and checked against `HOST_RE` (lib.sh's `cf_valid_name`
  rule), every existing domain of the page sent back, and a host that another page has (from
  `statusPageList`) refused before anything is saved. No page, or no `statusPageList` within
  15 s: nothing saved. Nothing to change: no save at all (so no group is rewritten).
- **Reading it.** `getStatusPage(slug)` answers `config: toJSON()`, which has `domainNameList`
  (from the static `StatusPage.domainMappingList`, `{domain: slug}`, reloaded by
  `loadDomainMappingList`). The public `/api/status-page/<slug>` (`toPublicJSON`) has no
  domains.
- **Serving it.** Not the status page router (slug paths only). `server.js` `GET /`: the hostname
  is `request.hostname` (no port), or `X-Forwarded-Host` when Kuma's `trustProxy` setting is on;
  when it is a key of `domainMappingList` (exact, case-sensitive), Kuma renders the page there,
  else it redirects to the entry page (`/dashboard` by default). `GET /api/entry-page` (public)
  answers `{type: "statusPageMatchedDomain", statusPageSlug}` for a mapped host, else `{type:
  "entryPage", entryPage}`; the SPA (`Entry.vue`) asks it on `/`. `status.sh` and `UPTIME.md`
  step 9e read that answer. Traefik passes the original `Host`, so `trustProxy` is not needed.
- **Everything else on that host is ordinary Kuma.** Static files, `/upload`,
  `/api/status-page/*`, `/api/badge/*`, `/api/push/*`, socket.io and the catch-all `index.html`
  answer on any host: `/dashboard` on the client's host is Kuma's login. There is no setting to
  fence a domain to its page; a Coolify path rule cannot either (`fqdnLabelsForTraefik` adds
  `PathPrefix` only for a URL with a path, and the page needs `/`). Written plainly in step 9a.
- **Cache.** `saveStatusPage` clears `apicache`, so the public JSON is fresh right after a save.

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
11. `statusPageList` arrives after the login: an object keyed by page id whose entries carry
    `slug` and `domainNameList`.
12. `saveStatusPage` with a new `domainNameList` answers `ok`; with Kuma's `trustProxy` off,
    `https://<client host>/api/entry-page` answers `{"type":"statusPageMatchedDomain",
    "statusPageSlug":"<slug>"}`, `/` renders the page and `/dashboard` there shows the login
    (expected, `UPTIME.md` step 9a).
13. `PATCH /services/{uuid}/applications/{app_uuid} {url: "a,b"}` answers 200, `GET
    /services/{uuid}` then shows `fqdn` `"a,b"` and `SERVICE_URL_UPTIMEKUMA_3001` is still the
    first domain; a used host gives the 409 shape of `references/coolify-api.md`.
14. `POST /services/{uuid}/restart` recreates the container with a router for the second domain
    and the same container name; the certificate for the client host arrives within about two
    minutes over a CNAME; how long the checks pause; plain http on the client host redirects to
    https.
15. `kuma_domain_remove`: the router is gone after the restart (what the client host answers
    then), Kuma drops the mapping, the page and its checks stay, and the public JSON is fresh
    right after the save.
