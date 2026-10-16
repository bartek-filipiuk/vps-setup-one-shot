# HANDOVER: give a project or a server to someone else

You are an AI coding agent helping a user who hands a server or a project to someone else: a
client who takes it over, or a colleague who joins. Work from the repo root of
`vps-setup-one-shot` (or with `SETUP_DIR` pointing at it, as in `PREPARE-APP.md`); every command
starts with `. ./lib.sh` and, for an app set up through PREPARE-APP, `VPS_STATE=.coolify.env` in
that app's repo. Rules from `SETUP.md` apply: API only via `capi`, server commands only via
`rssh`, nothing destructive without the user's yes, prove every step.

In this file **you** is the agent of whoever runs the step, **the developer** is the person
who set the server up and hands it over, **the new person** is the client or colleague. Steps 1
to 5 are the developer's; step 6 is run by the new person with their own agent and their own
copy of this repo. Secrets never go through the chat, a message or a file you send: each person
types their own tokens and keys into their own terminal.

**Not run on a real server yet.** `team_members` and `ssh_keys_list` are tested against a fake
Coolify API only (`test/lib.test.sh`). `GET /team/members` and `GET /security/keys` were checked
on a live Coolify 4.3.23; invites, roles and tokens have no API, so what this file says about
them comes from the 4.3.23 source and is marked `[verify]` (`references/coolify-api.md`, "Teams
and keys"). Nobody has taken over a server with this pack yet (step 7).

## 0. Pick the case

Ask the user which one it is; do not guess. The steps below are marked A, B or C where they
differ.

| Case | What changes hands | Coolify | Server SSH |
|------|--------------------|---------|------------|
| **A** a whole server to a client | everything: server, Coolify, repos, DNS, backups, alerts | the client becomes owner, the developer leaves | the client's key in, the developer's key out |
| **B** one project to a client, on a server the developer keeps | the repo and the domain of that project | see the limit below | none |
| **C** a colleague joins | nothing; one more person | member (admin if needed) | only if agreed |

**The limit of case B, say it plainly:** Coolify cannot isolate one project from the rest of a
team. A server belongs to one team, every member of that team sees every project on it, and API
tokens have no project or server scope. A client invited into the developer's team sees the
developer's other clients. So for case B offer one of these, and let the user choose:

- **No Coolify login for the client.** They get the repo (step 3); a push to `main` deploys
  through the webhook, which needs no Coolify access. The developer keeps running the server
  and reading logs for them.
- **The project moves to its own server**, which then goes over as case A: a second server
  with this setup (`SETUP.md`, then `PREPARE-APP.md` for the app) and the database brought over
  from a backup (`REBUILD.md` steps 3 to 6 on the new server). That server
  can sit in its own Coolify team on the same panel, or behind its own Coolify.

Inviting a case B client into the developer's team as a member is possible, but only after the
user has heard the sentence above and still says yes.

## 1. Who does what

Coolify has no API for invites, roles or tokens: these are clicks in the Coolify UI. Paths are
from the 4.3.23 source **[verify]**.

| What | Who | How | Case A | Case B | Case C |
|------|-----|-----|--------|--------|--------|
| invite | the developer | **Team** → **Members** (`/team/members`) → invite by email or copy the link; email plus role | `owner` | `member` (only after step 0) | `member` |
| accept | the new person | the link, then log in with a verified email; it expires after 3 days | yes | yes | yes |
| API token | the new person, their own | **Keys & Tokens** → **API Tokens** (`/security/api-tokens`) | `root` (their agent runs this guide) | `deploy` + `read` for CI | `deploy` + `read` for CI |
| token into their config | the new person | their own terminal | yes | yes | yes |
| remove the developer | the new owner | **Team** → **Members** | yes, remove (step 6) | no | no |

Notes:

- `admin` instead of `member` only when the person needs what an admin has: managing members
  and invites, and reading sensitive values (passwords, keys, webhook URLs) through the UI or a
  token with `read:sensitive` or `root`. An admin cannot invite an owner.
- Only an owner can make someone owner. In case A the developer, as owner, invites the client
  as `owner`; the client then demotes or removes the developer (step 6).
- Every role change and every removal in **Team** → **Members** also revokes that user's API
  tokens for the team **[verify]**.
- A token belongs to the team that is current when it is created (team switcher at the top of
  the UI), never to a project. Expiry: 7, 30, 60, 90 or 365 days, or none. A CI token gets an
  expiry.
- The new person writes their token with the command from phase 04 step 3 (`<COOLIFY_DOMAIN>`
  filled in before you give it to them), in their own terminal. Then their agent checks it:

  ```
  . ./lib.sh; capi GET /version && team_members
  ```

  Expect the version and a member list that includes them. `team_members` says on stderr that
  the role is not in the API; the role is in **Team** → **Members**. A `401` means a wrong or
  truncated token.

## 2. SERVER.md for this handover (the developer)

The summary is the one from phase 06 step 3. If anything changed since it was written (a new
app, backups, alerts), run that step again first (for an app from PREPARE-APP, with
`VPS_STATE=.coolify.env`). Then copy it into a handover folder and add who holds what. Fill in
the placeholders with the user before you run it; no secrets go in, only who holds them:

```
. ./lib.sh; d="$HOME/.config/vps-setup/handover"; mkdir -p "$d" && chmod 700 "$d" &&
cp "$HOME/.config/vps-setup/SERVER.md" "$d/SERVER.md" && cat >> "$d/SERVER.md" <<EOF

## Who holds what (handover $(date +%F), case <A|B|C>)

- Coolify: <NEW PERSON> as <owner|admin|member>; the developer: <removed|stays as ROLE>
- API tokens: each person has their own (Keys & Tokens -> API Tokens), never shared
- Server SSH (root): <NEW PERSON's key|the developer only>
- GitHub repo: $(state_get GH_REPO) -> <NEW OWNER>/<REPO> (owner <...>, collaborators <...>)
- DNS: $(state_get APP_DOMAIN) (and $(VPS_STATE=$VPS_SETUP_STATE state_get COOLIFY_DOMAIN) in case A) at <REGISTRAR>, account of <...>
- Hetzner project (server, Hetzner backups, Object Storage): account of <...>
- S3 keys (s3.env): <...>
- Alerts: Discord webhook in <...>'s Discord server, channel <...>
- Database password: only in Coolify (the database and the app's DATABASE_URL)
EOF
chmod 600 "$d/SERVER.md"; echo "written: $d/SERVER.md"
```

Show the user the file. Case B: delete the lines about the server, SSH, panel access and the
teardown before it goes out; they are not the client's. Case A: the new owner's agent also needs
the state; give them `~/.config/vps-setup/state` without the lines that are paths on the
developer's machine:

```
. ./lib.sh; ( umask 077; grep -vE '^(SETUP_DIR|APP_DIR|SSH_PUBKEY)=' "$VPS_SETUP_STATE" > "$HOME/.config/vps-setup/handover/state" ) && echo "written: $HOME/.config/vps-setup/handover/state"
```

It holds IPs, domains and UUIDs, no tokens. The new owner puts it at
`~/.config/vps-setup/state` (mode 600) and their agent sets `SETUP_DIR`, `APP_DIR` and
`SSH_PUBKEY` for their machine with `state_set`. The user sends both files the way they send
any document; nothing in them opens a door.

## 3. Repo (the developer, then whoever has admin on it)

Case A and B: the repo goes to the new owner. Case C: a collaborator.

Transfer (the new owner gives their GitHub login or organisation):

```
. ./lib.sh; gh api -X POST "repos/$(state_get GH_REPO)/transfer" -f new_owner="<NEW OWNER>" >/dev/null && echo "transfer requested; GitHub may show the old name until it is accepted"
```

A personal account has to accept the transfer from the email GitHub sends **[verify]**. Deploy
keys and webhooks move with the repo, and GitHub redirects the old name **[verify]**; still,
point Coolify at the new name, while the developer still has a token (if the private repo is no
longer visible to the developer after the transfer, the new owner runs this block **[verify]**):

```
. ./lib.sh; R="<NEW OWNER>/<REPO>"; gh repo view "$R" --json nameWithOwner -q .nameWithOwner &&
capi PATCH "/applications/$(state_get APP_UUID)" "$(jq -n --arg r "git@github.com:$R.git" '{git_repository:$r}')" >/dev/null &&
state_set GH_REPO "$R" && echo "repo: $R"
```

Collaborator instead (case C, or the developer stays on a transferred repo by agreement):

```
. ./lib.sh; gh api -X PUT "repos/$(state_get GH_REPO)/collaborators/<LOGIN>" -f permission=push >/dev/null && echo "invited <LOGIN> with push"
```

`push` is enough to deploy: a push to `main` deploys. They accept the invite on GitHub.

After a transfer, the new owner's agent checks what came along and rotates the webhook secret
(the developer generated it in phase 05 step 6, so the developer knows it). The deploy key needs
no rotation: its private half exists only in Coolify.

```
. ./lib.sh; R=$(state_get GH_REPO)
gh api "repos/$R/keys" --jq '.[] | "deploy key \(.id) \(.title) read_only=\(.read_only)"'
gh api "repos/$R/hooks" --jq '.[] | "hook \(.id) \(.config.url) \(.events | join(","))"'
```

Expect the `coolify` deploy key (`read_only=true`) and one hook to
`.../webhooks/source/github/events/manual` with `push`. Then the rotation (the two calls run
back to back; a push in between is rejected and simply not deployed):

```
. ./lib.sh; S=$(openssl rand -hex 24)
capi PATCH "/applications/$(state_get APP_UUID)" "$(jq -n --arg s "$S" '{manual_webhook_secret_github:$s}')" >/dev/null &&
jq -n --arg s "$S" '{secret:$s}' | gh api -X PATCH "repos/$(state_get GH_REPO)/hooks/$(state_get HOOK_ID)/config" --input - >/dev/null && echo "webhook secret rotated"
```

Then the test push from phase 05 step 6; expect `200`.

## 4. DNS (the developer and the new owner)

Find out with the user who owns the domain: the registrar account and the account where the
zone (the records) lives. If both are already the client's, nothing moves; only the records
must stay. If either is the developer's, the domain or the zone moves to the client's account
the way their registrar does it (a transfer with an auth code, or a push between accounts);
when the zone moves to another DNS provider, copy every record first (mail records too), not
only these.

The records this setup needs, from `SERVER.md` (case B: only the app's):

```
. ./lib.sh; for h in "$(VPS_STATE=$VPS_SETUP_STATE state_get COOLIFY_DOMAIN)" "$(state_get APP_DOMAIN)"; do
  echo "$h A=$(dig +short A "$h" @1.1.1.1 | tr '\n' ' ') AAAA=$(dig +short AAAA "$h" @1.1.1.1 | tr '\n' ' ') (want A=$(VPS_STATE=$VPS_SETUP_STATE state_get VPS_IP), no AAAA)"
done
```

Run it before and after the move. Any other answer: phase 01 step 4 (the records) and phase 04 step 1 (the check), and
`DOCTOR.md` (certificate error).

## 5. Secrets: who holds them after, how to rotate

Case C changes none of these. Case B: only the webhook secret (step 3) and the client's own
token.

| Secret | Where | After (case A) | Rotate |
|--------|-------|----------------|--------|
| SSH root key | the developer's `~/.ssh`, its public half in the server's `authorized_keys` | the new owner's key | step 6, in that order: add theirs, test, remove the developer's |
| Coolify API token | each person's `~/.config/coolify/config` | the new owner's own token | revoked when the developer is demoted or removed **[verify]**; a new one: **Keys & Tokens** → **API Tokens**, then phase 04 step 3 |
| S3 keys | the developer's `~/.config/vps-setup/s3.env` and Coolify's S3 storage | the new owner's key pair in their `s3.env` | new pair in the Hetzner Console (**Security** → **S3 credentials**), phase 06 step 1a command, then step 1b's `s3_storage_create vps-setup-backups ...` (updates the storage with the new pair), then delete the old pair in the Console |
| Discord webhook URL | the developer's `~/.config/vps-setup/notify.env` and Coolify | a webhook in the new owner's Discord server | phase 06 step 2a and 2b on their side; the developer deletes the old webhook in Discord |
| Database password | Coolify (the database, the app's `DATABASE_URL`) | unchanged | optional, see below |
| Hetzner API token and project | the developer's `hcloud` context `vps-setup` | the new owner's project and token | the project or its servers move in the Hetzner Console **[verify]**; the developer deletes the token (Console → **Security** → **API tokens**) and `hcloud context delete vps-setup` |
| GitHub webhook secret | Coolify and the GitHub hook | new value | step 3 |

Hetzner: whether a project, or a server inside it, can move to another account is the Console's
business and has not been tried here **[verify]**. If it cannot, the options are: the developer's
account keeps paying and the client pays the developer, or the server is rebuilt in the client's
project (`REBUILD.md`, as a planned move). Ask; do not pick.

The database password is reachable only inside the server's Docker network; once SSH and
Coolify access are gone, the old value opens nothing from outside. If the new owner still wants
it changed, they do it themselves in their own terminal (an interactive prompt needs a terminal, so this one
is plain `ssh -t`, not `rssh`): `ssh -t root@<VPS_IP> docker exec -it
<container of DB_UUID> psql -U app -d app -c '\password app'`, then the same value in Coolify
(the database's **Configuration** and the app's `DATABASE_URL`) and a redeploy **[verify]**.

## 6. Remove the developer's access (the new owner)

Case A. The new owner's agent runs this, from their machine, with their token and their state
(step 2). Case B and C: nothing here; when someone leaves the team later, 6.1 for that person.

### 6.1 Coolify

Read who is in the team:

```
. ./lib.sh; team_members
```

In **Team** → **Members** the new owner sees the roles. Case A: they remove the developer (a
`member` still sees every project in the team). Case C, a colleague who leaves: remove them, or
demote to `member` if they stay on other work. Then run `team_members` again: the developer is
gone (or the UI shows them as `member`). The developer checks their own token is dead, on their machine:

```
. ./lib.sh; capi GET /version >/dev/null 2>&1 && echo "token STILL WORKS - delete it in Keys & Tokens" || echo "token revoked"
```

and then deletes `~/.config/coolify/config`. If Coolify refuses to remove the developer because
their account is the instance's first user **[verify]**, the developer's account changes hands
instead: the new owner sets its email and password in **Profile** and turns on their own 2FA.

### 6.2 Server SSH

Never leave the server with no working key. Order: the developer adds the new owner's public
key (not secret; they send it, `~/.ssh/id_ed25519.pub`), the new owner proves it works, and only
then the developer's key goes.

The developer, before anything is removed (put the full public key line in):

```
. ./lib.sh; K="<NEW OWNER'S PUBLIC KEY LINE>"; rssh "grep -qxF -- '$K' ~/.ssh/authorized_keys || echo '$K' >> ~/.ssh/authorized_keys" && echo added
```

The new owner, on their machine:

```
. ./lib.sh; rssh true && echo "ssh ok" && rssh "ssh-keygen -lf ~/.ssh/authorized_keys"
```

Expect `ssh ok` and one line per key: fingerprint and comment. Three kinds belong there:
theirs, the developer's, and **Coolify's own key** (Coolify manages this host over SSH as root;
its comment looks like `root@coolify` **[verify]**). Never remove Coolify's key: Coolify loses
its server. Compare with what Coolify holds:

```
. ./lib.sh; ssh_keys_list
```

It prints uuid, name, fingerprint and whether a key is for git, never the key itself. Expect the
server's key and one deploy key per app; anything else, ask the developer what it is. (Coolify's
fingerprint format may differ from `ssh-keygen -lf` **[verify]**.)

Then remove the developer's key, by its base64 part (the second field of the public key line,
`AAAA...`). The command refuses unless both keys are present and the new owner's key is still
there afterwards; it keeps a copy:

```
. ./lib.sh; OLD="<DEVELOPER'S KEY, BASE64 PART>"; NEW="<NEW OWNER'S KEY, BASE64 PART>"
rssh "f=~/.ssh/authorized_keys; grep -qF -- '$NEW' \$f && grep -qF -- '$OLD' \$f && cp -p \$f \$f.bak &&
grep -vF -- '$OLD' \$f.bak > \$f.new && grep -qF -- '$NEW' \$f.new && cat \$f.new > \$f && rm \$f.new && ssh-keygen -lf \$f || echo 'nothing changed'"
```

Prove it from a **new** connection while the old one could still fix things:

```
. ./lib.sh; rssh true && echo "ssh ok"
```

The developer runs the same and expects it to fail. Then the backup copy goes:
`rssh "rm ~/.ssh/authorized_keys.bak"`. In the Hetzner project the developer's `vps-setup` SSH
key (used only when a server is created or rescued) is replaced: `hcloud ssh-key delete
vps-setup` in the new owner's context, and their own key added if they want one.

### 6.3 Repo, alerts, backups, Hetzner

- Repo: step 3's check; `gh api "repos/$(state_get GH_REPO)/collaborators" --jq '.[].login'`
  lists who can push. The developer stays only by agreement.
- Alerts and S3: the rows in step 5. `notify_status` and `./status.sh` (the `alerts` and
  `off-site` lines) must be OK afterwards.
- Hetzner: members and API tokens of the project in the Console; the developer's are gone.

### 6.4 The developer's machine

When the new owner confirms all of the above, the developer deletes, after a yes:
`~/.config/coolify/config`, `~/.config/vps-setup/` (state, `s3.env`, `notify.env`, `SERVER.md`,
`handover/`) and the `hcloud` context. Their local copy of the app repo is theirs to keep or
delete.

## 7. Done when

A second user, with only this pack (`SERVER.md` from step 2, their own token and key, the repo),
deploys a change: a push to `main`, the deployment `finished`, the change visible on the domain,
and step 6 shows the developer gone. That is the R12 done criterion. **Not run yet**: no server
has been handed over with this file; the first harness run will be the proof.
