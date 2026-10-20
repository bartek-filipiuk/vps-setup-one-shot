# CHECKUP: the monthly look at the server

You are an AI coding agent running the monthly checkup of a user's server, on a schedule the
user set up for you or because they asked. Work from the repo root of `vps-setup-one-shot` (or
with `SETUP_DIR` pointing at it, as in `PREPARE-APP.md`). Rules from `SETUP.md` apply: API only
via `capi`, server commands only via `rssh`, nothing destructive without the user's yes, prove
every step.

**Not run on a real server yet.** `checkup.sh` and its helpers in `lib.sh` (`checkup_server_facts`,
`firewall_rules`, `firewall_applied`, `hcloud_json`, `coolify_advisories`,
`backup_success_rate`, `server_cost`, the checkup log, `vault_check`) are tested against a fake Coolify API, a
fake GitHub advisories answer, a fake `hcloud` and fake server tools only (`test/lib.test.sh`,
`test/checkup.test.sh`). Which containers of a clean Coolify mount the Docker socket, the
`hcloud` JSON fields, the shape of the advisories answer and how long Coolify keeps backup runs
come from the Coolify 4.3.23 source and the Hetzner and GitHub API documentation and are marked
`[verify]` here and in `references/coolify-api.md`.

**Read only.** The checkup changes nothing on the server, in Coolify or at Hetzner: `rssh` runs
`ss`, `sshd -T`, `ssh-keygen -l`, `ps`, `docker inspect`, `df` and `du`; `capi` only `GET`;
`hcloud` only `list` and `describe` (through `hcloud_json`, which refuses anything else). Port
probes go from this machine to the server's public IP. The one write is a line in the checkup
log on this machine (`~/.config/vps-setup/checkup.log`, mode 600, no secrets): disk numbers and
the monthly cost, so next month can say how fast the disk grows. A fix happens only after the
user's yes, through the runbook named next to it.

## 1. When and how

Once a month, and after anything big (a new app, a rebuild, an upgrade). `status.sh` is the
everyday screen; the checkup runs it first and adds what changes slowly: ports against the
cloud firewall, the SSH daemon, Docker exposure, Coolify security advisories, the backup success
rate of the last 30 days, disk growth since the last checkup and what the servers cost.

A schedule is the user's choice: their agent's own scheduler, or a reminder to ask for it. On a
Hetzner server the cost and firewall checks need `hcloud` logged in (phase 01 step 1). The
advisories come from GitHub without a token: 60 calls an hour, plenty for once a month.

## 2. Run

```
./checkup.sh; echo "exit $?"
```

Exit `0`: all OK. `1`: something needs attention. `2`: the server or the Coolify API did not
answer; go to `DOCTOR.md` section E first, the rest of the checkup can wait.

The output is `status.sh`'s screen, then the monthly sections, then **Actions**: every `WARN`
and `FAIL` line, from `status.sh` too, each with the runbook that fixes it:

```text
Actions
  FAIL  docker socket                mounted by portainer (portainer/portainer-ce:2.21, rw): each of them controls the server -> CHECKUP.md 3c
  WARN  cert app.example.com         expires in 10 days -> DOCTOR.md D
```

`CHECKUP_RECORD=0 ./checkup.sh` skips the log line (a second run the same day, a test).

## 3. What each line means and the fix

Lines that come from `status.sh` (ssh, disk, updates, version, apps, certificates, uptime,
backups, postgres, alerts) point at the runbooks `status.sh` already uses: `DOCTOR.md`,
`UPGRADE.md`, `SERVICES.md`, `UPTIME.md`, phase 06. The monthly lines:

### 3a. Firewall and listening ports

`firewall` (Hetzner): the rules of `vps-setup-fw` against phase 01 step 2 (in: tcp 22, 80, 443
and icmp) and whether it is applied to the server. An extra inbound rule is `FAIL`: something
is open that the setup never opened. A port opened on purpose (Forgejo's 22222 in `SERVICES.md`)
is recorded once with `. ./lib.sh; state_set CHECKUP_PORTS_OK tcp/22222` (several: space
separated) and is OK from then on. Not applied to the server is `FAIL`: everything Docker
publishes is on the internet.

`firewall` (another provider): the host firewall of phase 02 step 4 (`vps-hostfw`), read from
its own status on the server, against the same ports. `OK` reads `host (vps-hostfw on eth0): in
tcp/22 tcp/80 tcp/443 icmp only, IPv4 and IPv6, DOCKER-USER guarded, persisted`. Each problem is
added to the line:

| Words in the line | Mark | Meaning |
|-------------------|------|---------|
| `extra open: tcp/<port>` | FAIL | a port open that the setup never opened (or not recorded in `CHECKUP_PORTS_OK`) |
| `missing tcp/<port>` | WARN | a base port is not in the rules (80 missing: certificates cannot renew) |
| `no drop rule in INPUT` | FAIL | the host's own ports are open to everyone |
| `DOCKER-USER rules missing`, `... without -i <iface> or without the drop` | FAIL | Docker's published ports (8000 the panel) are not guarded |
| `another rule comes first in DOCKER-USER` | FAIL | a rule above ours lets traffic through first |
| `DOCKER-USER is not used by FORWARD`, `Docker uses its nftables backend` | FAIL | Docker no longer reads `DOCKER-USER`; Docker can run an nftables backend that has no such chain **[verify]** |
| `IPv6 opens ..., IPv4 ...` | FAIL | the two families differ |
| `not persisted` | WARN | the rules are in place now but not after a reboot |
| `vps-hostfw.service failed` | FAIL | the boot unit failed: after the last boot or Docker restart the rules may be missing (`rssh 'journalctl -u vps-hostfw -n 20'`) |
| `a trial is pending` | WARN | someone ran a trial and did not confirm it; it removes itself |
| `n/a (no host firewall ...)` | WARN | `vps-hostfw` not installed (a setup from before R20, or phase 02 step 4 skipped) |

On another provider the rules are only as good as the interface they guard: the `listening`
line below is the outside proof.

`listening`: every TCP port the server listens on, on a public address, outside the firewall's
ports, probed from this machine. A clean Coolify listens on 8000, 6001, 6002 and 8080 (its
dashboard, realtime, terminal and the proxy's dashboard) on all addresses; they must be closed
from the internet, and the cloud firewall closes them **[verify]**. `reachable from the internet`
is `FAIL`. UDP is listed, not probed (Coolify's proxy has 443/udp for HTTP/3).

Fix, only after the user's yes: remove the extra rule (`hcloud firewall delete-rule vps-setup-fw
--direction in --protocol tcp --port <port> --source-ips 0.0.0.0/0 --source-ips ::/0`), apply the
firewall (`hcloud firewall apply-to-resource vps-setup-fw --type server --server
"$(state_get SERVER_NAME)"`). On another provider: an extra port opened on purpose with
`hostfw_port_add`, closed with `hostfw_port_remove <port>`; anything else (rules missing,
unguarded, shadowed, not persisted) is fixed by running phase 02 step 4 again from its step 1,
trial and confirm included, which puts every rule back in place. `DOCKER-USER is not used` with
Docker's nftables backend: stop, this needs a human (the host firewall cannot guard Docker's
ports there **[verify]**; `references/providers.md`).
A reachable port with no firewall rule for it on Hetzner means the firewall is not applied, or
the probe went somewhere else (VPN, a proxy on this machine): run `./checkup.sh` again from
another network before changing anything.

### 3b. SSH daemon

`sshd`: `sshd -T` against phase 02 step 3: password and keyboard-interactive login off, empty
passwords off, keys on, root by key only (`permitrootlogin without-password` is how sshd prints
`prohibit-password`). Anything else is `FAIL`; the fix is phase 02 step 3, in its order, so
nobody gets locked out. Look for a second drop-in in `/etc/ssh/sshd_config.d/` that sorts before
`00-hardening.conf`, or a `Match` block, with `rssh 'ls /etc/ssh/sshd_config.d/; grep -n Match
/etc/ssh/sshd_config'`.

`root keys`: the keys in `/root/.ssh/authorized_keys`, by type and fingerprint (comments are not
printed). Always `OK`: the user decides whether each key belongs. One is theirs, one is
Coolify's own (`ssh_keys_list` shows its fingerprint); a key nobody can name is removed along
`HANDOVER.md`, after the user's yes, never the only one that works.

### 3c. Docker

`docker api`: the Docker API on TCP (`dockerd -H tcp://...`, `"hosts"` in
`/etc/docker/daemon.json`, or a listener on 2375 or 2376). Whoever reaches it is root on the
server: `FAIL`. Coolify does not need it; it talks to Docker over SSH. Fix, after the user's
yes: remove the `-H tcp://...` from the systemd override (`systemctl cat docker`) or the `tcp://`
entry from `daemon.json`, then `systemctl daemon-reload && systemctl restart docker` (every
container restarts; a short downtime).

`docker socket`: containers that mount `/var/run/docker.sock`. Coolify's own (`coolify-proxy`,
`coolify-sentinel`, the short-lived `coolify-helper` builds; `DOCKER_SOCK_OK` in `lib.sh`
**[verify]**) are expected. Any other one controls the server: `FAIL` with its name and image.
Ask the user what it is. If it is not theirs, or not needed, it is removed from Coolify
(`SERVICES.md` removal for a service) after their yes.

`docker privileged`: privileged containers outside Coolify's own: `WARN`. A VPN or monitoring
agent may need it; the user confirms it is theirs.

### 3d. Coolify advisories

The published security advisories of the Coolify repository on GitHub, compared with the
installed version. `FAIL advisory GHSA-...` affects this version: upgrade to the fixed version
or newer with `UPGRADE.md` section A, soon. `WARN` without a version range: read the advisory
(`https://github.com/coollabsio/coolify/security/advisories/<GHSA id>`) and tell the user in one
sentence what it is about and whether it applies; once read, record it so it stays quiet:
`. ./lib.sh; state_set CHECKUP_ADVISORIES_SEEN "<id> <older ids>"`. `n/a` with a rate limit:
run again in an hour.
The first run usually lists a few advisories without a range; one round of marking them seen
keeps later runs quiet.

### 3e. Backup success rate

Per database, the backup runs of the last 30 days: how many succeeded and how many copies
reached S3. A failed run or upload is `WARN`, fewer than half successful or no run at all is
`FAIL`. Coolify deletes old run records along with old local backups, so a short history (7 runs
with 7 kept locally) is not a failure **[verify]**. Fix: the newest failure's message
(`db_backup_list <DB_UUID>`), then phase 06 step 1 (schedule, storage, key pair).

`status.sh`'s `WARN off-site ... S3 upload not reported by API` is expected on Coolify 4.3.23,
whose API was not seen returning `s3_uploaded` **[verify]**: the Actions list points it at
`RESTORE.md` step 3, and only a restore from the bucket proves the copy. Until then a clean
server ends with this one `WARN`; say so to the user instead of treating it as new.

### 3f. Disk growth

The used disk now against the newest checkup sample at least 20 days old, projected to 85%.
Under a month to 85% is `FAIL`, under three months `WARN`. The line also shows the local
backups (`/data/coolify/backups`), the deploy dumps (`/root/db-dumps`) and what Docker could
reclaim. What is safe to clear and how: `DOCTOR.md` section C ("disk full" in
`references/troubleshooting.md`), each step after the user's yes. More disk means a bigger
server type or a volume: the user's decision and money.

### 3g. Cost

Hetzner: every server in the hcloud project with its list price (gross, the location's price)
and +20% when its backups are on, the change since the last checkup, and how many primary IPs
and volumes there are. Their price, Object Storage and traffic are not in `hcloud`: the user
reads them in the Hetzner Console → **Usage**. More than one server is `WARN`: often the old
one after a rebuild (`REBUILD.md` step 10), still billed; only the user deletes it. Another
provider: `n/a`, the invoice is the source.

### 3h. Secrets vault

`vault_check` (`VAULT.md`): when the encrypted copy of this setup's secrets was made and whether
a file with a secret (the env files, the Coolify config, the hcloud config, the ssh key)
changed after it or is not in it. It reads the manifest and the file's first two lines only,
never decrypts. `no vault yet` or `stale` is `WARN`: the user runs `vault_export` in their own
terminal (`VAULT.md` step 2), then puts the new file off the machine. Changes to the state,
`SERVER.md` and `PROJECTS.md` (every deploy) hold no secret and do not count.

## 4. Report to the user

One short message: the result line, then the Actions list as it is, each item with its runbook,
most serious first. Nothing is fixed during the checkup; each fix is proposed in one sentence
and done only after an explicit yes, through its runbook. Say what was not checked (`n/a`
lines) and why. A clean month is one sentence.

## Fixtures (not built yet)

How the test harness (roadmap R01, R16) will prove this file on a throwaway server: a clean
setup first, then one thing broken at a time. Not run yet; the steps are the plan.

```text
clean:        phases 01-06 on a fresh server       -> exit 0, no WARN or FAIL line
docker api:   dockerd -H tcp://0.0.0.0:2375         -> FAIL docker api, CHECKUP.md 3c
socket:       a container with /var/run/docker.sock -> FAIL docker socket naming it
sshd:         PasswordAuthentication yes            -> FAIL sshd, CHECKUP.md 3b
firewall:     a vps-setup-fw rule for tcp/8000      -> FAIL firewall and FAIL listening 8000
```

The R16 done criterion: on the clean setup the checkup has no false positive.
