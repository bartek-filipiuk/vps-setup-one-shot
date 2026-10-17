# 05 Starter app

**Done when** `https://APP_DOMAIN/api/health` returns `"db":"ok"` over valid HTTPS, a waitlist
signup from the browser lands in Postgres, and push-to-deploy is either working or explicitly
recorded as not available (`WEBHOOK=none`).

Tell the user: "Now the fun part: I create a private GitHub repo from the starter, a Postgres
database and the app in Coolify, and deploy it to your domain. You'll click almost nothing."

Every step records what it created. Before creating anything, check the state: if the UUID is
already there, verify it with a GET and reuse it instead of creating a duplicate. A recorded
UUID that is empty or `null` means that step failed: read the error printed above it, fix the
cause, and run the step again.

## 1. Repo (you)

```
. ./lib.sh; N=$(state_get APP_NAME); DEST="$HOME/$N"
if test -e "$DEST"; then echo "EXISTS: $DEST, ask the user"; else
  cp -R starter "$DEST" && rm -rf "$DEST/node_modules" "$DEST/.next" &&
  ( cd "$DEST" && git init -q -b main && git add -A && git commit -q -m "Initial commit from vps-setup-one-shot starter" &&
    gh repo create "$N" --private --source . --push ) &&
  state_set APP_DIR "$DEST" &&
  state_set GH_REPO "$(gh repo view "$N" --json nameWithOwner -q .nameWithOwner)" && echo "repo: $(state_get GH_REPO)"
fi
```

The `cd` runs in a subshell on purpose: your shell must stay in this repo for `. ./lib.sh`.
If `$DEST` exists, ask whether to use a different name. If it is this starter from an earlier
attempt: when `gh repo view "$N"` works, only record `APP_DIR` and `GH_REPO` as above; when the
GitHub repo is missing, run `gh repo create "$N" --private --source "$DEST" --push` first.

## 2. Deploy key (you)

Coolify clones the private repo with a read-only key that only works for this one repo:

```
. ./lib.sh; K=$(mktemp -d); ssh-keygen -q -t ed25519 -N '' -C "coolify-$(state_get APP_NAME)" -f "$K/key" &&
gh repo deploy-key add "$K/key.pub" --repo "$(state_get GH_REPO)" --title coolify &&
U=$(capi POST /security/keys "$(jq -n --arg n "$(state_get APP_NAME)-deploy" --rawfile k "$K/key" '{name:$n, private_key:$k}')" | jq -r .uuid) &&
[ -n "$U" ] && [ "$U" != null ] && state_set KEY_UUID "$U" && rm -rf "$K" && echo "key: $U" || echo "FAILED, key kept in $K"
```

The private key exists only in Coolify afterwards; the local copy is deleted once Coolify has it.
If the upload failed, retry the `capi POST` with the key in `$K` instead of generating a new one,
so GitHub does not collect orphaned deploy keys (`gh repo deploy-key list --repo <repo>`).

## 3. Project and Postgres (you)

One Coolify project per client or product, one environment per stage. The setup's own project is
named after the app and runs in `production`. `project_ensure` finds the project by name or
creates it, so a second run creates no duplicate; it records `PROJECT_UUID` and `PROJECT_NAME`,
`env_ensure` records `ENV_NAME`:

```
. ./lib.sh; project_ensure "$(state_get APP_NAME)" "created by vps-setup-one-shot" &&
env_ensure "$(state_get PROJECT_UUID)" production
```

If it says that several projects have this name, ask the user which one is theirs and to rename
the other in the Coolify UI (**Projects**), then run it again.

The database goes into that project and environment (`project_ctx` prints both):

```
. ./lib.sh; read -r P E < <(project_ctx) &&
B=$(openssl rand -hex 24 | jq -Rn --arg p "$P" --arg e "$E" --arg s "$(coolify_server)" \
  --arg n "$(state_get APP_NAME)-db" \
  '{project_uuid:$p, server_uuid:$s, environment_name:$e, name:$n,
    image:"postgres:17-alpine", postgres_user:"app", postgres_password:input, postgres_db:"app",
    is_public:false, instant_deploy:true}') &&
state_set DB_UUID "$(capi POST /databases/postgresql "$B" | jq -r .uuid)"; echo "db: $(state_get DB_UUID)"
```

Postgres 17, not 18: Coolify mounts the data volume at `/var/lib/postgresql/data`, which the 18
image refuses. The password is hex so it never needs URL-escaping, and it is never printed.

Wait until it runs (up to two minutes):

```
. ./lib.sh; for _ in $(seq 1 12); do s=$(capi GET "/databases/$(state_get DB_UUID)" | jq -r .status); echo "$s"; case "$s" in running*) break;; esac; sleep 10; done
```

## 4. Application (you)

```
. ./lib.sh; read -r P E < <(project_ctx) &&
B=$(jq -n --arg p "$P" --arg e "$E" --arg s "$(coolify_server)" \
  --arg n "$(state_get APP_NAME)" --arg r "git@github.com:$(state_get GH_REPO).git" --arg k "$(state_get KEY_UUID)" \
  '{project_uuid:$p, server_uuid:$s, environment_name:$e, name:$n,
    git_repository:$r, git_branch:"main", build_pack:"dockerfile", ports_exposes:"3000",
    private_key_uuid:$k, instant_deploy:false}') &&
state_set APP_UUID "$(capi POST /applications/private-deploy-key "$B" | jq -r .uuid)"; echo "app: $(state_get APP_UUID)"

A=$(state_get APP_UUID)
capi PATCH "/applications/$A" "$(jq -n --arg d "https://$(state_get APP_DOMAIN)" \
  '{domains:$d, health_check_enabled:true, health_check_path:"/api/health", health_check_port:"3000"}')" >/dev/null &&
URL=$(capi GET "/databases/$(state_get DB_UUID)" | jq -r .internal_db_url) &&
capi POST "/applications/$A/envs" "$(printf '%s' "$URL" | jq -Rs '{key:"DATABASE_URL", value:., is_preview:false}')" >/dev/null &&
echo "domain, health check and DATABASE_URL set"
```

Do not print `$URL`; it contains the database password. The health check makes Coolify keep the
old version running if the new one cannot reach the database.

## 5. First deploy (you, 3-6 minutes)

```
. ./lib.sh; deploy_and_wait "$(state_get APP_UUID)"
```

It first prints the rollback point (`none` on this first deploy) and dumps the database over
`rssh` to `/root/db-dumps/<DB_UUID>/` on the server (empty now, but the path is proven), then
deploys. From the second deploy on, it ends with the exact commands that go back to the previous
version (`ROLLBACK.md`).

On `failed`, read the log tail it prints and match it against `references/troubleshooting.md`.
Fix the cause, then deploy again. Do not loop more than twice on the same error; explain it to
the user instead.

Then wait for HTTPS and the database (the first certificate takes up to about three minutes):

```
. ./lib.sh; for i in $(seq 1 18); do r=$(curl -s --max-time 10 "https://$(state_get APP_DOMAIN)/api/health"); echo "try $i: ${r:-no valid https yet}"; case "$r" in *'"db":"ok"'*) break;; esac; sleep 10; done
```

## 6. Push-to-deploy (you)

A GitHub webhook calls Coolify on every push to `main`. It uses a secret that can only trigger
this app, never the API token.

```
. ./lib.sh; if [ -n "$(state_get HOOK_ID)" ]; then echo "hook $(state_get HOOK_ID) exists"; else S=$(openssl rand -hex 24) &&
capi PATCH "/applications/$(state_get APP_UUID)" "$(printf '%s' "$S" | jq -Rs '{manual_webhook_secret_github:.}')" >/dev/null &&
H=$(printf '%s' "$S" | jq -Rs --arg u "$(coolify_get COOLIFY_URL)/webhooks/source/github/events/manual" \
  '{name:"web", active:true, events:["push"], config:{url:$u, content_type:"json", secret:.}}' |
  gh api -X POST "repos/$(state_get GH_REPO)/hooks" --input - --jq .id) && state_set HOOK_ID "$H" && echo "hook $H"; fi
```

Test with a real push:

```
. ./lib.sh; git -C "$(state_get APP_DIR)" commit -q --allow-empty -m "Test push-to-deploy" && git -C "$(state_get APP_DIR)" push -q && sleep 15 &&
gh api "repos/$(state_get GH_REPO)/hooks/$(state_get HOOK_ID)/deliveries" --jq '.[] | select(.event=="push") | "\(.status_code) \(.delivered_at)"' | head -1
```

Expect `200`. The user can watch the build: Coolify → **Projects** → their project →
its environment (`production`) → the app → **Deployments**. Then `state_set WEBHOOK github`.

If the PATCH is rejected (this Coolify version has no such field) or deliveries show a non-200
code you cannot fix, do not improvise: delete the hook (`gh api -X DELETE repos/<repo>/hooks/<id>`),
`state_set WEBHOOK none`, and tell the user that deploys are triggered with
`. ./lib.sh; deploy_and_wait <APP_UUID>` from this repo, or from the Coolify UI with **Deploy**.

## 7. Smoke test with the user

They open `https://<APP_DOMAIN>`, enter their email, click **Send me the repo**, and should see
"You're on the list." and the counter at 1 after a reload. You prove the row is in Postgres
(the database container's name contains its UUID):

```
. ./lib.sh; rssh "docker exec \$(docker ps -q -f name=$(state_get DB_UUID)) psql -U app -d app -tAc 'select count(*) from waitlist'"
```

## 8. Per-project config (you)

So the user's other tools (for example a `coolify-deploy` skill) know this app:

```
. ./lib.sh; D=$(state_get APP_DIR)
printf 'COOLIFY_PROJECT_UUID=%s\nCOOLIFY_APP_UUID=%s\nCOOLIFY_DOMAIN=https://%s\nPROJECT_NAME=%s\nPROJECT_UUID=%s\nENV_NAME=%s\n' \
  "$(state_get PROJECT_UUID)" "$(state_get APP_UUID)" "$(state_get APP_DOMAIN)" \
  "$(state_get PROJECT_NAME)" "$(state_get PROJECT_UUID)" "$(state_get ENV_NAME)" > "$D/.coolify.env" &&
git -C "$D" check-ignore -q .coolify.env && echo "written, gitignored"
```

Run `./verify.sh`.
