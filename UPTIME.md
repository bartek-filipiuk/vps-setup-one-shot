# UPTIME: uptime checks and a public status page for your apps

You are an AI coding agent helping a user who wants to know when an app is down and to show
its state on a public status page. This file sets up Uptime Kuma as a Coolify one-click service
(`SERVICES.md`), takes over its first-start pages before anyone else can, adds one check per app
domain and a status page per project, and reads the result. Work from the repo root of
`vps-setup-one-shot` (or with `SETUP_DIR` pointing at it, as in `PREPARE-APP.md`); every command
starts with `. ./lib.sh`. Rules from `SETUP.md` apply: API only via `capi`, server commands only
via `rssh`, nothing destructive without the user's yes, prove every step.

**Not run on a real server yet.** `kuma_env_init`, `kuma_init`, `kuma_targets`, `kuma_sync`,
`kuma_status`, `kuma.js` and the `status.sh` Uptime section are tested against a fake Coolify
API, a stubbed `ssh`, a fake `docker` and a fake Kuma only (`test/lib.test.sh`,
`test/status.test.sh`, `test/kuma.test.js`). The Kuma socket events and HTTP answers come from
the Uptime Kuma 2.x source and are marked `[verify]` in `references/uptime-kuma.md`. No Kuma has
been set up with this file yet.

## 1. What you get, and what not

- One HTTP check per https domain of every app in the project and stage (the setup's project and
  `production`, or `VPS_PROJECT` and `VPS_ENV` as in `SERVICES.md`), every 60 seconds; a check
  that fails twice in a row (one retry after 30 seconds) marks the app down.
- A public status page per project, `https://<KUMA_DOMAIN>/status/<slug>`. **Anyone with the link
  sees the app names, their domains and whether they are up.** Ask the user before you make one
  for a client's project.
- `status.sh` gets an Uptime section with a line per check.
- Not included: Kuma's own notifications (the alerts are Coolify's, phase 06 step 2), a custom
  domain per status page, backups of Kuma's volume (step 8).
- Kuma runs on the same server as the apps. When the whole server is down, Kuma is down with
  it and its page does not answer; `./status.sh` on the user's machine shows that (`ssh` and
  `api` FAIL). There is no outside check yet.

## 2. Create Kuma (you, with the user)

Follow `SERVICES.md` steps 1 to 3 with `TYPE` `uptime-kuma`, `NAME` `uptime-kuma` and a domain
such as `status.<DOMAIN>` (the user picks it; `<KUMA_DOMAIN>` below). **Stop before
`SERVICES.md` step 4** and come back here.

Why: Uptime Kuma 2.x starts with two public pages, first the database type, then "create the
admin". Whoever opens them first owns the monitor. Step 3 fills both from this machine, through
the container, before the domain has a certificate.

## 3. The admin login, before anyone else (user, then you)

The user runs this in their own terminal, in the repo folder (it writes a random password into
`~/.config/vps-setup/kuma.env`, mode 600, and prints only the path):

```
. ./lib.sh; kuma_env_init
```

Expect `wrote ~/.config/vps-setup/kuma.env (mode 600): ...`. It refuses when the file exists:
then it is the login of a Kuma made before, and it stays.

Then you wait for the container (the image is pulled first). Replace `<NAME>` with the name
from step 2 (`uptime-kuma`), as in `SERVICES.md`:

```
. ./lib.sh; u=$(state_get "SERVICE_<NAME>_UUID"); for i in $(seq 1 30); do
  st=$(service_status "$u" | awk -F'\t' '$1 == "app" { print $4 }'); echo "try $i: ${st:-?}"
  case $st in running*) break ;; esac; sleep 10; done
```

As soon as it says `running:healthy` (or `running:unknown`):

```
. ./lib.sh; kuma_init "<NAME>"
```

Expect `Kuma database set up (SQLite)`, `admin admin created; the password is in ...` and
`recorded UPTIME_SERVICE=<NAME>, UPTIME_URL=https://<KUMA_DOMAIN>`. Run again it says
`already initialised` and changes nothing. What else it can say:

- `Kuma is not running yet (...)`: wait a minute, run it again.
- `no Kuma login: ... is missing`: the user has not run `kuma_env_init` yet.
- `kuma.js gave no result: ...`: the container did not run the script (the message says why:
  no running container, no `socket.io-client` in the image, ssh). Read the Kuma logs in the
  Coolify UI (project → the service → **Logs**); do not loop.
- `admin exists and kuma.env does not open it`: someone created the admin first. If it was not
  the user, the password must be reset at once; this needs a human. The user runs, in their own
  terminal, with the server's IP and the service uuid (`state_get SERVICE_<NAME>_UUID`):
  `ssh -t root@<VPS_IP> docker exec -it uptime-kuma-<uuid> npm run reset-password` **[verify]**
  and, when it asks, types the `KUMA_PASSWORD` from `kuma.env` (`cat ~/.config/vps-setup/kuma.env`
  in their own terminal). If that admin is not called `admin`, they change the `KUMA_USER=` line
  to its name. Then `kuma_init` again.

## 4. HTTPS (you), then the first login (user)

Now `SERVICES.md` step 4 (the HTTPS wait, `service_status`, `projects_md`). Then the user opens
`https://<KUMA_DOMAIN>` and logs in with the two lines of `cat ~/.config/vps-setup/kuma.env`,
read in their own terminal. Turning on 2FA in Kuma stops step 5 from working (step 8).

## 5. Checks and the status page (you)

```
. ./lib.sh; kuma_sync
```

For a client's project, after the user's yes to a public page for it (and `VPS_ENV=<stage>` in
front for another stage):

```
. ./lib.sh; VPS_PROJECT="<project name>" kuma_sync
```

The page is named after the project (slug `acme-corp` for `Acme Corp`); another slug and title:
`kuma_sync "<slug>" "<title>"`. Expect `monitors added: ...`, `monitors kept: ...` and
`status page: https://<KUMA_DOMAIN>/status/<slug>`. A second run adds only what is new. It
never deletes a monitor, a page or a group: checks and groups made by hand in Kuma stay.
What else it can say:

- `no application with an https domain in this project and environment`: nothing to check yet.
- `2FA is on for the Kuma admin`: step 8.
- `admin exists and kuma.env does not open it`: the password was changed in Kuma; step 3.

Then read the page, as anyone on the internet can (no login):

```
. ./lib.sh; for i in $(seq 1 12); do out=$(kuma_status); rc=$?; echo "try $i: exit $rc"
  printf '%s\n' "$out" | grep -qE $'\t(pending|none)\t' || break; sleep 10; done; printf '%s\n' "$out"
```

Every row should be `up` within two minutes (the first checks are `pending` or `none`). Kuma
caches the public page for up to 5 minutes (the heartbeats for 1), so right after the first
`kuma_sync` this can lag behind Kuma itself; wait and read again. Exit 1 means a check is
`down`. The reason (a 502, a timeout, a certificate error) is not on the public page (Kuma sends
no message there; the `msg` column stays `-`): the user sees it on the monitor's page in Kuma.
That app goes through `DOCTOR.md`. Exit 2 means the page could not be read: check that
`https://<KUMA_DOMAIN>/status/<slug>` opens in a browser. Give the user the page's address.

## 6. Prove it (only with the user's yes, never on a production app without one)

The proof that a down app shows: stop an app nobody depends on (the starter app of a fresh
setup is the usual one), see it go down, start it again. Ask the user first and name the app.
Not run on a server yet.

1. The user stops it in Coolify (project → the app → **Stop**).
2. Within about two minutes:

```
. ./lib.sh; for i in $(seq 1 18); do out=$(kuma_status); rc=$?; echo "try $i: exit $rc"
  [ "$rc" = 1 ] && break; sleep 10; done; printf '%s\n' "$out"
```

   Expect exit 1 and the app's row `down` (the page is cached, so allow a few minutes more). The user opens the status page and sees it red.
3. The user starts the app again (**Deploy** or **Start**); the same loop with `[ "$rc" = 0 ]`
   shows it `up` again.

## 7. Everyday

- A new app or a new domain: `. ./lib.sh; kuma_sync` again (with the same `VPS_PROJECT` for a
  client's project). It adds the new checks to the same page.
- `./status.sh` shows an `uptime <monitor>` line per check: `up`, `down since <time>` (FAIL),
  `pending` or `no check yet` (WARN); why it is down is on the monitor's page in Kuma.
- An app removed: its check stays in Kuma; delete it there by hand (`kuma_sync` never deletes).
- A check deleted in Kuma comes back with the next `kuma_sync`; one taken off the page comes
  back on it. To stop checking an app without deleting the check, pause it in Kuma: a paused
  check keeps its URL, so `kuma_sync` leaves it as it is.

## 8. Backups, 2FA, removal

- Kuma's volume (checks, history, pages) has no backup (`SERVICES.md` step 5). After a rebuild
  or on a new Kuma, steps 2 to 5 bring the checks and the pages back from the apps; the history
  is gone. `kuma.env` is kept and opens the new Kuma too (`kuma_init` creates the admin with it).
- 2FA on the Kuma admin: `kuma_sync` cannot log in with it and says so. Either the user turns
  it off for a sync (Kuma → **Settings** → **Security**), or new checks are added by hand.
- Removing Kuma: `SERVICES.md` step 6, on the user's yes (it deletes the volume with every check
  and page). Then clear the state, so `status.sh` stops reading the page:

```
. ./lib.sh; state_set UPTIME_SERVICE ''; state_set UPTIME_URL ''; state_set UPTIME_PAGES ''
```

  `kuma.env` stays on the user's machine; they delete it when they do not want a Kuma again
  (`rm ~/.config/vps-setup/kuma.env`, in their own terminal).
