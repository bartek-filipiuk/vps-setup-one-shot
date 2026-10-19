# UPTIME: uptime checks and a public status page for your apps

You are an AI coding agent helping a user who wants to know when an app is down and to show
its state on a public status page. This file sets up Uptime Kuma as a Coolify one-click service
(`SERVICES.md`), takes over its first-start pages before anyone else can, adds one check per app
domain and a status page per project, and reads the result. Work from the repo root of
`vps-setup-one-shot` (or with `SETUP_DIR` pointing at it, as in `PREPARE-APP.md`); every command
starts with `. ./lib.sh`. Rules from `SETUP.md` apply: API only via `capi`, server commands only
via `rssh`, nothing destructive without the user's yes, prove every step.

**Not run on a real server yet.** `kuma_env_init`, `kuma_init`, `kuma_targets`, `kuma_sync`,
`kuma_status`, `kuma.js` and the `status.sh` Uptime section, and for step 9 `dns_check`,
`kuma_domain_add`, `kuma_domain_remove`, `service_app`, `service_app_urls_set` and
`service_restart`, are tested against a fake Coolify API, a stubbed `ssh`, a fake `docker`, a
fake `dig` and a fake Kuma only (`test/lib.test.sh`, `test/status.test.sh`,
`test/kuma.test.js`). The Kuma socket events and HTTP answers come from the Uptime Kuma 2.x
source and are marked `[verify]` in `references/uptime-kuma.md`, the Coolify calls of step 9 in
`references/coolify-api.md`. No Kuma has been set up with this file yet, and no client domain
mapped.

## 1. What you get, and what not

- One HTTP check per https domain of every app in the project and stage (the setup's project and
  `production`, or `VPS_PROJECT` and `VPS_ENV` as in `SERVICES.md`), every 60 seconds; a check
  that fails twice in a row (one retry after 30 seconds) marks the app down.
- A public status page per project, `https://<KUMA_DOMAIN>/status/<slug>`. **Anyone with the link
  sees the app names, their domains and whether they are up.** Ask the user before you make one
  for a client's project. On the client's own domain too, if they want (step 9).
- `status.sh` gets an Uptime section with a line per check.
- Not included: Kuma's own notifications (the alerts are Coolify's, phase 06 step 2), backups
  of Kuma's volume (step 8).
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
- The page on the client's own domain (`status.client.com`): step 9.
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
  and page, and with them the client domains of step 9; tell those clients first, their records
  then point at nothing). Then clear the state, so `status.sh` stops reading the page:

```
. ./lib.sh; state_set UPTIME_SERVICE ''; state_set UPTIME_URL ''; state_set UPTIME_PAGES ''; state_set UPTIME_DOMAINS ''
```

  `kuma.env` stays on the user's machine; they delete it when they do not want a Kuma again
  (`rm ~/.config/vps-setup/kuma.env`, in their own terminal).

## 9. A client's domain for a status page

### 9a. What it does, and what it exposes (ask the user)

The page of a client's project (step 5) is served at `/` of a host of the client's, such as
`status.client.com`, with its own certificate, as well as at
`https://<KUMA_DOMAIN>/status/<slug>`. It is the same Kuma: one more domain on the Kuma service
in Coolify, and that host mapped to the page in Kuma. Say this to the user before anything,
plainly:

- On that host only `/` is the page. Every other path is ordinary Kuma: `/dashboard` shows
  Kuma's login page and `/status/<other slug>` shows another client's page if someone guesses
  the slug. Kuma has no setting that fences a domain to its page, and Traefik through Coolify
  cannot either (a page needs `/`, and a path rule on `/` matches everything). Nothing new opens:
  the same login answers on `https://<KUMA_DOMAIN>` already, and the other pages are public
  anyway. Only do it for a client the user is fine to show Kuma's login address to.
- Adding or removing a domain restarts Kuma: every check pauses for about a minute.
- The client creates a DNS record in their own zone; this guide never changes a client's DNS.

Ask: which project's page (the slug from step 5, `kuma_sync` printed it), which host (a
subdomain, `status.client.com`; not the bare `client.com`), and who manages the client's DNS.

### 9b. The record (the client, or you in the user's own zone)

In the client's zone, one record for exactly that host (a CNAME is not possible on the bare
domain, so it is always a subdomain):

- **CNAME** `status.client.com` -> `<KUMA_DOMAIN>` (recommended: it follows the server's address
  and survives a rebuild), or an **A** record to the server's `VPS_IP`;
- no AAAA record;
- on Cloudflare: **DNS only** (grey cloud), not proxied, or Traefik cannot get the certificate.

Give the client those three lines with `<KUMA_DOMAIN>` and the IP filled in. When the host is in
the user's own Cloudflare zone (`DNS_PROVIDER=cloudflare`), you create it instead, as in
`SERVICES.md` step 1:

```
. ./lib.sh; dns_set_a "<CLIENT_HOST>" "$(state_get VPS_IP)"
```

`<CLIENT_HOST> is not in the Cloudflare zone` means it is the client's zone: they make it.

### 9c. DNS gate (you)

A domain added before DNS points at the server gets no certificate, and every try counts
against Let's Encrypt's limits. Replace `<CLIENT_HOST>` in every command of this step:

```
. ./lib.sh; for i in $(seq 1 30); do dns_check "<CLIENT_HOST>"; rc=$?; [ "$rc" = 1 ] || break; sleep 60; done; echo "exit $rc"
```

Each try prints `A=<the server's IP> AAAA= CNAME=<KUMA_DOMAIN or nothing>`; `exit 0` is a
match, `exit 2` means it cannot check (no `dig`: install it). It follows a CNAME. If it does not match after a while, go through the three lines of 9b with the
client (an orange cloud or an old AAAA record are the usual causes).

### 9d. Map the host (you)

```
. ./lib.sh; kuma_domain_add "<slug>" "<CLIENT_HOST>"
```

It checks the DNS again, then maps the host to the page in Kuma, then adds `https://<CLIENT_HOST>`
to the Kuma service's domains in Coolify (Kuma's own domain stays first) and restarts the service.
Expect `Kuma: <CLIENT_HOST> now serves status page <slug>`, `domains of uptime-kuma: ...`,
`restarting` and `recorded <slug>=<CLIENT_HOST> in UPTIME_DOMAINS`. A second run changes
nothing and does not restart. What else it can say:

- `DNS of ... does not point at this server ... yet; nothing changed`: back to 9c.
- `... is not in UPTIME_PAGES; run kuma_sync for it first`: step 5 for that project first.
- `... is already used by ... in Coolify` or `already used in Coolify: ...`: the host belongs to
  another app or service; the client picks another host, or that one is freed first.
- `kuma.js: <host> is on status page <other>; nothing changed`: another page has the host. Kuma
  would take it from that page silently, so it is refused; ask the user which page it belongs to.
- `2FA is on for the Kuma admin`: step 8.
- `Kuma has <host> on the page, Coolify does not route it yet`: fix what the line above it says
  and run the same command again.

### 9e. HTTPS, then the user looks (you, then the user)

Coolify asks Let's Encrypt for the certificate once Traefik has the new router (a minute or
two after the restart):

```
. ./lib.sh; for i in $(seq 1 30); do
  t=$(curl -fsS --max-time 10 "https://<CLIENT_HOST>/api/entry-page" 2>/dev/null | jq -r '.type // empty' 2>/dev/null)
  echo "try $i: ${t:-no answer}"; [ "$t" = statusPageMatchedDomain ] && break; sleep 10; done
```

`statusPageMatchedDomain` means the host is the page. `entryPage` means Kuma answers but does
not know the host as a page (run 9d again). No answer after five minutes: the certificate
(`DOCTOR.md`, certificate error) or the DNS (9c). Then `projects_md` (the project gets a
`Status page:` line with the client's domain) and the user opens `https://<CLIENT_HOST>` and
sees the page. From now on `./status.sh` has a `page <slug>` line for it, and the `cert
<CLIENT_HOST>` line under the Kuma service.

Do not edit the Kuma service's domains in the Coolify UI afterwards: Kuma's own domain must stay
the first one (`kuma_init` and Coolify's `SERVICE_URL_UPTIMEKUMA_3001` take the first).

### 9f. Removing it (on the user's yes)

```
. ./lib.sh; kuma_domain_remove "<slug>" "<CLIENT_HOST>" --yes
```

Coolify first (the host stops routing, Kuma restarts), then Kuma drops the mapping; the page,
its checks and its other domains stay. Then the client deletes their record; this guide never
deletes DNS records. After a rebuild (`REBUILD.md`) the mapping is gone with the old Kuma: run
9d again on the new server (a CNAME to `<KUMA_DOMAIN>` already points there).
