# SERVICES: self-hosted tools next to your apps

You are an AI coding agent helping a user who wants a tool of their own on their server:
analytics, automation, an uptime monitor or a Git host, each on its own domain with HTTPS.
Coolify ships these as one-click services; this file drives them through its API. Work from the
repo root of `vps-setup-one-shot` (or with `SETUP_DIR` pointing at it, as in `PREPARE-APP.md`);
every command starts with `. ./lib.sh` and uses the global setup state (the project from phase
05). Rules from `SETUP.md` apply: API only via `capi`, server commands only via `rssh`, nothing
destructive without the user's yes, prove every step.

**Not run on a real server yet.** `service_create`, `service_status`, `service_delete` and the
`status.sh` Services section are tested against a fake Coolify API only (`test/lib.test.sh`,
`test/status.test.sh`). `GET /services` and `GET /services/{uuid}` were checked on a live
Coolify 4.3.23; creating a service with a domain, the 409 and 422 answers, delete and the
templates come from the 4.3.23 source and are marked `[verify]` (`references/coolify-api.md`,
"Services"). No service has been created with this file yet.

## Supported services

One way per tool. Each runs as a Coolify service in the setup's project (environment
`production`), with its data in Docker volumes on the server.

| Tool | `TYPE` | What it needs | First login (user, right after HTTPS works) |
|------|--------|---------------|---------------------------------------------|
| Umami (web analytics) | `umami` | its own Postgres inside the service (not the app's database), one volume for it | default account `admin` / `umami`: change the password at once **[verify]** |
| n8n (automation) | `n8n` | SQLite in a volume | the first visitor creates the owner account **[verify]** |
| Uptime Kuma (uptime monitor) | `uptime-kuma` | SQLite in a volume | the first visitor creates the admin account |
| Forgejo (Git hosting) | `forgejo` | its database and repositories in a volume; Git over SSH on host port 22222 | the first visitor finishes the install page and registers the admin **[verify]** |

The first visitor becomes admin for n8n, Uptime Kuma and Forgejo, and Umami's default password
is public: the address is on the internet from the moment HTTPS works, so the user logs in
within minutes of step 4, not tomorrow.

Forgejo over HTTPS needs nothing more. Git over SSH needs port 22222 open in the cloud firewall,
which only allows 22, 80 and 443 (phase 01). Only if the user wants it, and after their yes:

```
hcloud firewall add-rule vps-setup-fw --direction in --protocol tcp --port 22222 \
  --source-ips 0.0.0.0/0 --source-ips ::/0
```

On `PROVIDER=other` the user adds the same rule in their provider's firewall; `ufw` is not
enough, because Docker bypasses it.

**Not supported yet:** MinIO and Plausible are not one-click templates on Coolify 4.3.23
(Coolify ignores them), MinIO only as a hand-written compose file. Any other template is not
supported yet either; one is added after a run on a server (`SERVICE_TYPES` in `lib.sh`).

## 1. Pick the tool and its domain (user)

Ask which tool from the table, a short name for it (lower case, digits, dashes; usually the
type) and its domain, a subdomain of theirs such as `stats.<DOMAIN>`. The user adds an **A**
record for that name pointing at `VPS_IP`, and no AAAA record (as in phase 01, step 4).

With `DNS_PROVIDER=cloudflare` you create the record instead (replace `<SERVICE_DOMAIN>`):

```
. ./lib.sh; dns_set_a "<SERVICE_DOMAIN>" "$(state_get VPS_IP)"
```

Expect `A created -> <ip>` (or `unchanged`), DNS only. `exit 1` (a CNAME or several A records)
and `exit 2` (an AAAA record) are read as in phase 01, step 4: the user removes the extra record
in Cloudflare.

## 2. DNS gate (you)

A service created before DNS points at the server gets no certificate, and every retry counts
against Let's Encrypt's limits. So check first. Replace `<SERVICE_DOMAIN>` in every command of
this file before you run it:

```
. ./lib.sh; IP=$(state_get VPS_IP); h="<SERVICE_DOMAIN>"
echo "$h A=$(dig +short A "$h" @1.1.1.1 | tr '\n' ' ') AAAA=$(dig +short AAAA "$h" @1.1.1.1 | tr '\n' ' ') (want A=$IP, no AAAA)"
```

It must show `A=<VPS_IP>` and an empty AAAA. If not, re-check the record with the user (typos
and the Cloudflare orange cloud are the usual causes). Wait and re-check every minute; do not
continue until it matches.

## 3. Create it (you)

Replace `<TYPE>` and `<NAME>` too:

```
. ./lib.sh; service_create "<TYPE>" "<NAME>" "<SERVICE_DOMAIN>"
```

Expect `service <NAME> (<TYPE>) created: <uuid>, recorded as SERVICE_<NAME>_UUID` (the name in
upper case, dashes as underscores) and `domain: https://<SERVICE_DOMAIN>`. Coolify starts
pulling the images at once. What else it can say:

- `domain ... is already used by ...`: another app or service has that domain. Pick another
  one, or ask the user whether the other resource should give it up. Nothing was created.
- `Coolify refused the service (HTTP 422): ...`: Coolify's reason, usually a domain it does not
  accept. Nothing was created.
- `service type ... is not supported`, `not a domain name`: the input; fix it and run again.

Running it twice with the same domain answers with the conflict, so there is no second copy.

## 4. Wait for HTTPS (you)

```
. ./lib.sh; for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://<SERVICE_DOMAIN>" || true)
  echo "try $i: $code"; [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 400 ] && break; sleep 10; done
```

Expect 200 or 302 within about five minutes (the images are pulled first). `000` means no valid
certificate yet; 502 or 503 means the container is not up yet. Then:

```
. ./lib.sh; service_status "$(state_get "SERVICE_<NAME>_UUID")"
```

Every row should be `running:healthy` (or `running:unknown` for a container without a health
check) and the `app` row should carry `https://<SERVICE_DOMAIN>`. Still `000` or `502` after
five minutes: `restart_limit` `yes` or an `exited` row means the container keeps crashing; read
its logs in the Coolify UI (project → the service → **Logs**) and see "HTTPS" in
`references/troubleshooting.md` for the certificate. Do not delete and recreate it in a loop:
each attempt counts against Let's Encrypt's limits.

Now the user does the first login from the table, at once. `./status.sh` has a `service <NAME>`
line and a `cert <SERVICE_DOMAIN>` line from now on.

## 5. Backups

Phase 06 backs up the app's database. A service's data is not in that backup.

- **A database inside the service** (Umami's Postgres): the API has no backup call for it
  (`/databases/{uuid}/backups` covers standalone databases only). The user sets it up in the
  Coolify UI **[verify]**: project → the service → its database (`postgresql`) → **Backups** →
  add a scheduled backup, daily, with **S3** on and the storage from phase 06 step 1
  (`vps-setup-backups`), 7 kept locally and 30 in S3 like the app's. Then **Backup now** once and
  check that the run ends as success. `RESTORE.md` and `db_restore` do not cover these
  databases yet.
- **Volumes** (n8n, Uptime Kuma, Forgejo; Umami keeps its data in its Postgres): the 4.3.23
  source has volume backups for services (`/services/{uuid}/storages/{storage_uuid}/backups`),
  but they have not been run and `lib.sh` does not drive them yet **[verify]**. Until then the
  only copy of these volumes is a Hetzner server backup, if the user chose one in phase 06
  (`state_get BACKUPS`). Say that plainly: without it, these volumes have no backup.

`status.sh` cannot see the backups of a service's database: its Backups section reads standalone
databases only. A backup set up in the UI is checked there, under the service's database →
**Backups** → executions.

## 6. Remove a service (only on the user's yes)

Deleting a service deletes its volumes: its database, its files, every repository in Forgejo,
every workflow in n8n. Gone for good, unless a backup from step 5 exists. Say that in one
sentence, name the service, and wait for an explicit yes to exactly this. Then:

```
. ./lib.sh; service_status "$(state_get "SERVICE_<NAME>_UUID")" && service_delete "$(state_get "SERVICE_<NAME>_UUID")" --yes
```

Without `--yes` it refuses and sends nothing; never add `--yes` before the user's yes.
`delete_volumes=true` is what removes the data. The A record stays: this guide never deletes
DNS records (with `DNS_PROVIDER=cloudflare`, `. ./lib.sh; dns_list "<SERVICE_DOMAIN>"` shows it).
The user deletes it in their DNS provider (Cloudflare: DNS → Records), and, for Forgejo, the 22222 firewall rule if it was added
(`hcloud firewall delete-rule vps-setup-fw --direction in --protocol tcp --port 22222 --source-ips 0.0.0.0/0 --source-ips ::/0`).
