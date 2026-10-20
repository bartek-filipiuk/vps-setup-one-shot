#!/usr/bin/env bash
# Builds every fixture in fixtures/, the worker in starter-worker/ (R24, WORKER.md) and the
# sign-in app in starter-auth/ (R24, AUTH.md) with Docker and checks the health contract: 200
# {"status":"ok","db":<expected>} on 127.0.0.1, the same answer on [::1] inside the container,
# the image's HEALTHCHECK passing, a non-root user, and for fixtures with a database 503
# {"status":"error","db":"error"} once the database is stopped. For the worker also: a job
# enqueued with enqueue.js (argument and stdin) runs, the cron slots are claimed, an unknown
# kind is refused. For starter-auth also a whole sign-in by email link (MAIL_LOG=1: the mail is
# read from the container's log, nothing is sent): the confirm page, single use, the session
# cookie, the protected page, other-site posts refused, the per-address limit, sign-out.
# No server; needs Docker with
# a recent compose v2 (up --wait --wait-timeout), curl, jq and openssl.
# Everything it creates is named vps-fixture-<name>-<pid> and removed by that name on exit;
# nothing is pruned. The Postgres password comes from openssl rand and goes through the
# environment, never argv.
# Usage: bash test/fixtures.sh [static|python-fastapi|go|compose|starter-worker|starter-auth ...]   (prints ALL FIXTURES OK)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# name port db kind dir (the build context)
TABLE='static 8080 none dockerfile fixtures/static
python-fastapi 8000 ok dockerfile fixtures/python-fastapi
go 8080 ok dockerfile fixtures/go
compose 8080 ok compose fixtures/compose
starter-worker 3000 ok dockerfile starter-worker
starter-auth 3000 ok dockerfile starter-auth'
# Images that define no HEALTHCHECK on purpose: starter-auth has the starter's Dockerfile byte
# for byte (test/starter-variants.sh), and Coolify's own health check calls /api/health. Any other
# image without one fails.
NO_HEALTHCHECK=" starter-auth "
PG_IMAGE=postgres:17-alpine
WAIT=${FIXTURE_WAIT_SECONDS:-90}

fails=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected [$3] got [$2]"; fails=$((fails + 1)); fi; }

containers=(); images=(); networks=(); projects=()
cleanup() {
  local c
  for c in ${containers[@]+"${containers[@]}"}; do docker rm -fv "$c" >/dev/null 2>&1; done
  for c in ${projects[@]+"${projects[@]}"}; do
    docker compose -f fixtures/compose/compose.yaml -f test/fixtures-compose.ci.yaml -p "$c" \
      down -v --rmi local --remove-orphans >/dev/null 2>&1
  done
  for c in ${images[@]+"${images[@]}"}; do docker rmi "$c" >/dev/null 2>&1; done
  for c in ${networks[@]+"${networks[@]}"}; do docker network rm "$c" >/dev/null 2>&1; done
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# get URL: sets code and body
get() {
  local out
  out=$(curl -s -m 5 -w '\n%{http_code}' "$1" 2>/dev/null) || out=$'\n000'
  code=${out##*$'\n'}; body=${out%$'\n'*}
}

# wait_for URL CODE: poll until URL answers CODE or WAIT seconds pass
wait_for() {
  local i
  for ((i = 0; i < WAIT; i++)); do
    get "$1"
    [ "$code" = "$2" ] && return 0
    sleep 1
  done
  return 1
}

# contract NAME URL CODE STATUS DB: the health answer has exactly this shape
contract() {
  wait_for "$2" "$3"
  check "$1: health HTTP code" "$code" "$3"
  check "$1: health status" "$(jq -r .status <<<"$body" 2>/dev/null)" "$4"
  check "$1: health db" "$(jq -r .db <<<"$body" 2>/dev/null)" "$5"
  check "$1: health has no other keys" "$(jq -c 'keys' <<<"$body" 2>/dev/null)" '["db","status"]'
}

# in_container NAME CONTAINER PORT DB: IPv6 loopback answer, image HEALTHCHECK, user
in_container() {
  local name=$1 c=$2 port=$3 db=$4 v6 user hc
  # A throwaway container in the app container's network namespace; distroless has no shell.
  if [ "$(docker run --rm --network "container:$c" "$PG_IMAGE" cat /proc/sys/net/ipv6/conf/lo/disable_ipv6 2>/dev/null)" = 0 ]; then
    v6=$(docker run --rm --network "container:$c" "$PG_IMAGE" wget -qO- -T 5 "http://[::1]:$port/api/health" 2>/dev/null)
    check "$name: health on [::1]" "$(jq -r '.status + "/" + .db' <<<"$v6" 2>/dev/null)" "ok/$db"
  else
    echo "skip $name: health on [::1] (IPv6 disabled in this Docker's containers)"
  fi
  user=$(docker inspect -f '{{.Config.User}}' "$c")
  case $user in ''|root|0|0:*|root:*) check "$name: runs as a non-root user" "${user:-<empty>}" "<non-root>" ;;
    *) check "$name: runs as a non-root user" non-root non-root ;; esac
  if [ "$(docker inspect -f '{{json .Config.Healthcheck}}' "$c")" = null ] && [[ $NO_HEALTHCHECK == *" $name "* ]]; then
    echo "skip $name: image HEALTHCHECK and Docker health status (the image defines none; Coolify's health check calls /api/health)"
    return
  fi
  hc=$(docker inspect -f '{{json .Config.Healthcheck.Test}}' "$c")
  local -a cmd=()
  case $(jq -r '.[0]' <<<"$hc") in
    CMD) mapfile -t cmd < <(jq -r '.[1:][]' <<<"$hc") ;;
    CMD-SHELL) cmd=(sh -c "$(jq -r '.[1]' <<<"$hc")") ;;
  esac
  if [ "${#cmd[@]}" -gt 0 ] && docker exec "$c" "${cmd[@]}" >/dev/null 2>&1; then hc=0; else hc=1; fi
  check "$name: image HEALTHCHECK exits 0" "$hc" 0
  local i status=
  for ((i = 0; i < WAIT; i++)); do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c")
    [ "$status" = healthy ] && break
    sleep 1
  done
  check "$name: Docker health status" "$status" healthy
}

# tail_out TEXT: the last 40 lines of a failed build or compose up, indented
tail_out() { tail -n 40 <<<"$1" | sed 's/^/     /'; }

dump_logs() { echo "     logs of $1:"; docker logs --tail 30 "$1" 2>&1 | sed 's/^/     /'; }

# psql_db CONTAINER SQL: one value from the test database
psql_db() { docker exec "$1" psql -U app -d app -tAc "$2" 2>/dev/null; }

# worker_checks NAME CONTAINER: the starter-worker's queue and cron against the real Postgres
worker_checks() {
  local name=$1 c=$2 i got rc
  docker exec "$c" node enqueue.js echo '{"ci":1}' >/dev/null 2>&1; rc=$?
  check "$name: enqueue.js with a JSON argument" "$rc" 0
  printf '%s' '{"ci":2}' | docker exec -i "$c" node enqueue.js echo - >/dev/null 2>&1; rc=$?
  check "$name: enqueue.js with the payload on stdin" "$rc" 0
  for ((i = 0; i < WAIT; i++)); do
    got=$(psql_db "$c-db" "select count(*) from jobs where status = 'done' and payload->>'ci' in ('1', '2')")
    [ "$got" = 2 ] && break
    sleep 1
  done
  check "$name: both jobs ran (status done)" "$got" 2
  check "$name: cron slots claimed (heartbeat, prune)" "$(psql_db "$c-db" "select string_agg(distinct name, ',' order by name) from cron_runs")" "heartbeat,prune"
  check "$name: the cron jobs ran" "$(psql_db "$c-db" "select count(*) >= 2 from jobs where status = 'done' and payload->>'ci' is null")" t
  # A kind without a handler, inserted the way a web app would: fail() end to end.
  psql_db "$c-db" "insert into jobs (kind, payload) values ('no_handler', '{\"ci\":3}')" >/dev/null
  for ((i = 0; i < WAIT; i++)); do
    got=$(psql_db "$c-db" "select status || ':' || (last_error is not null) || ':' || (lock_token is null) from jobs where payload->>'ci' = '3'")
    [ "${got%%:*}" = failed ] && break
    sleep 1
  done
  check "$name: a kind without a handler ends failed with last_error, unlocked" "$got" "failed:true:true"
  docker exec "$c" node enqueue.js nope '{}' >/dev/null 2>&1; rc=$?
  check "$name: an unknown kind is refused" "$rc" 1
  docker exec "$c" node enqueue.js echo '[1]' >/dev/null 2>&1; rc=$?
  check "$name: a payload that is not an object is refused" "$rc" 1
  got=$(docker exec "$c" node enqueue.js stats 2>/dev/null); rc=$?
  check "$name: enqueue.js stats" "$rc:$(grep -c '^done [0-9]* 0$' <<<"$got")" "0:1"
}

# req URL [CURL ARGS...]: one request, no redirects followed; sets code, body, hdrs (the response
# headers), loc (Location) and setck (Set-Cookie)
req() {
  local u=$1 out; shift
  out=$(curl -s -m 10 -D - -w '\n%{http_code}' "$@" "$u" 2>/dev/null | tr -d '\r') || out=$'\n000'
  code=${out##*$'\n'}; out=${out%$'\n'*}
  hdrs=${out%%$'\n\n'*}; body=${out#*$'\n\n'}
  loc=$(grep -i '^location:' <<<"$hdrs" | cut -d' ' -f2-)
  setck=$(grep -i '^set-cookie:' <<<"$hdrs" | cut -d' ' -f2-)
}

# auth_checks NAME CONTAINER HOSTPORT: a whole sign-in against the real Postgres. SITE_URL in the
# container is http://127.0.0.1:3000, so that is the Origin a form from the site carries; the
# link from the mail is rewritten to the published port.
auth_checks() {
  local name=$1 c=$2 hp=$3 o=http://127.0.0.1:3000 line link tk ck i n
  local -a form=(-H "Origin: $o" --data-urlencode)
  mails() { docker logs "$c" 2>/dev/null | grep '^mail: {' | grep -c "\"to\":\"$1\""; }
  check "$name: the MAIL_LOG warning at start" "$(docker logs "$c" 2>/dev/null | grep -c '^mail: MAIL_LOG=1, nothing is sent')" 1
  req "http://$hp/"
  check "$name: the sign-in page" "$code:$(grep -c 'action="/api/auth/sign-in"' <<<"$body")" "200:1"
  req "http://$hp/api/auth/sign-in" "${form[@]}" email=CI@example.com
  check "$name: sign-in request" "$code $loc" "303 /?sent=1"
  req "http://$hp/api/auth/sign-in" -H "Origin: https://evil.example" --data-urlencode email=ci@example.com
  check "$name: a sign-in posted from another site" "$code" 403
  req "http://$hp/api/auth/sign-in" --data-urlencode email=ci@example.com
  check "$name: a sign-in without Origin or Referer" "$code" 403
  req "http://$hp/api/auth/sign-in" "${form[@]}" email=not-an-address
  check "$name: an invalid address" "$code $loc" "303 /?error=invalid"
  req "http://$hp/api/auth/sign-in" "${form[@]}" email=big@example.com -d "pad=$(head -c 5000 /dev/zero | tr '\0' a)"
  check "$name: a valid address in a body over 4 KB is refused" "$code $loc" "303 /?error=invalid"
  for ((i = 0; i < 10; i++)); do [ "$(mails ci@example.com)" -ge 1 ] && break; sleep 1; done
  check "$name: exactly one mail logged for the address" "$(mails ci@example.com)" 1
  line=$(docker logs "$c" 2>/dev/null | grep '^mail: {' | grep -m1 '"to":"ci@example.com"')
  line=${line#mail: }
  link=$(jq -r .text <<<"$line" 2>/dev/null | grep -oE 'http://127\.0\.0\.1:3000/auth/callback\?token=[A-Za-z0-9_-]{43}')
  check "$name: the mail has one sign-in link" "$(grep -c . <<<"$link")" 1
  check "$name: the mail subject" "$(jq -r .subject <<<"$line" 2>/dev/null)" "Sign in to 127.0.0.1"
  tk=${link##*token=}
  check "$name: the raw token is not in the database" "$(psql_db "$c-db" "select count(*) from login_tokens where token_hash = '$tk'")" 0
  req "http://$hp/auth/callback?token=$tk"
  check "$name: the confirm page" "$code:$(grep -c 'action="/api/auth/callback"' <<<"$body"):$(grep -c 'ci@example.com' <<<"$body")" "200:1:1"
  check "$name: the confirm page sends no referrer to other sites" "$(grep -c '<meta name="referrer" content="same-origin"' <<<"$body")" 1
  check "$name: the confirm page is not cached" "$(grep -i '^cache-control:' <<<"$hdrs" | grep -c 'no-store')" 1
  check "$name: opening the link used nothing" "$(psql_db "$c-db" "select count(*) from login_tokens where used_at is null")" 1
  req "http://$hp/api/auth/callback" -H "Origin: https://evil.example" --data-urlencode "token=$tk"
  check "$name: a confirm posted from another site" "$code" 403
  req "http://$hp/api/auth/callback" "${form[@]}" "token=$tk"
  check "$name: confirm" "$code $loc" "303 /account"
  ck=$(grep -oE '^session=[A-Za-z0-9_-]{43}' <<<"$setck")
  check "$name: session cookie attributes" "${ck:+${setck#"$ck"}}" "; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax"
  req "http://$hp/account" -b "$ck"
  check "$name: the protected page with the cookie" "$code:$(grep -c 'ci@example.com' <<<"$body")" "200:1"
  req "http://$hp/account"
  check "$name: the protected page without it" "${code:0:2} $loc" "30 /"
  req "http://$hp/api/auth/callback" "${form[@]}" "token=$tk"
  check "$name: the link a second time" "$code $loc" "303 /?error=expired"
  req "http://$hp/auth/callback?token=$tk"
  check "$name: the confirm page for a used link" "$code:$(grep -c 'action="/api/auth/callback"' <<<"$body")" "200:0"
  check "$name: one user, lowercased" "$(psql_db "$c-db" "select string_agg(email, ',') from users")" "ci@example.com"
  check "$name: the token is used" "$(psql_db "$c-db" "select count(*) from login_tokens where used_at is not null")" 1
  check "$name: one session" "$(psql_db "$c-db" "select count(*) from sessions")" 1
  for ((i = 1; i <= 6; i++)); do
    req "http://$hp/api/auth/sign-in" "${form[@]}" email=limit@example.com
    [ "$code $loc" = "303 /?sent=1" ] || break
  done
  check "$name: six requests for one address all answer sent" "$i" 7
  for ((i = 0; i < 10; i++)); do n=$(mails limit@example.com); [ "$n" -ge 5 ] && break; sleep 1; done
  sleep 1
  check "$name: only five of them sent a mail" "$(mails limit@example.com)" 5
  check "$name: no mail from the body over 4 KB" "$(mails big@example.com)" 0
  req "http://$hp/api/auth/sign-out" -H "Origin: https://evil.example" -b "$ck" -d x=1
  check "$name: a sign-out posted from another site" "$code" 403
  req "http://$hp/api/auth/sign-out" -H "Origin: $o" -b "$ck" -d x=1
  check "$name: sign-out" "$code $loc $(grep -c 'Max-Age=0' <<<"$setck")" "303 / 1"
  check "$name: no session left" "$(psql_db "$c-db" "select count(*) from sessions")" 0
  req "http://$hp/account" -b "$ck"
  check "$name: the old cookie no longer opens the protected page" "${code:0:2} $loc" "30 /"
}

run_dockerfile() {
  local name=$1 port=$2 db=$3 dir=$4 n="vps-fixture-$1-$$" hp f0=$fails
  local -a extra=()
  # starter-auth: log-only mail (nothing is ever sent from a test) and its public address.
  case $name in starter-auth) extra=(-e MAIL_LOG=1 -e SITE_URL=http://127.0.0.1:3000 -e "MAIL_FROM=Test <test@example.com>") ;; esac
  echo "== $name"
  docker network create "$n" >/dev/null && networks+=("$n") || { check "$name: network" failed created; return; }
  if [ "$db" = ok ]; then
    # Password only through the environment: `docker run -e NAME` takes the value from it.
    POSTGRES_PASSWORD=$(openssl rand -hex 16) || { check "$name: openssl rand" failed ok; return; }
    export POSTGRES_PASSWORD POSTGRES_USER=app POSTGRES_DB=app
    export DATABASE_URL="postgres://app:$POSTGRES_PASSWORD@$n-db:5432/app"
    containers+=("$n-db")
    docker run -d --name "$n-db" --network "$n" -e POSTGRES_PASSWORD -e POSTGRES_USER -e POSTGRES_DB \
      "$PG_IMAGE" >/dev/null || { check "$name: postgres started" failed ok; return; }
  fi
  local out
  if ! out=$(docker build -t "$n" "$dir" 2>&1); then
    tail_out "$out"; check "$name: docker build" failed ok; return
  fi
  images+=("$n")
  echo "ok   $name: docker build"
  if [ "$db" = ok ]; then
    local i
    for ((i = 0; i < WAIT; i++)); do docker exec "$n-db" pg_isready -q -h 127.0.0.1 -U app -d app && break; sleep 1; done
    containers+=("$n")
    docker run -d --name "$n" --network "$n" -p "127.0.0.1::$port" -e DATABASE_URL ${extra[@]+"${extra[@]}"} "$n" >/dev/null
  else
    containers+=("$n")
    docker run -d --name "$n" --network "$n" -p "127.0.0.1::$port" "$n" >/dev/null
  fi
  hp=$(docker port "$n" "$port/tcp" | grep -m1 '^127\.0\.0\.1:')
  contract "$name" "http://$hp/api/health" 200 ok "$db"
  in_container "$name" "$n" "$port" "$db"
  case $name in
    starter-worker) worker_checks "$name" "$n" ;;
    starter-auth) auth_checks "$name" "$n" "$hp" ;;
  esac
  if [ "$db" = ok ]; then
    docker stop "$n-db" >/dev/null
    contract "$name (db stopped)" "http://$hp/api/health" 503 error error
  fi
  [ "$fails" = "$f0" ] || dump_logs "$n"
  unset POSTGRES_PASSWORD DATABASE_URL
}

run_compose() {
  local name=$1 port=$2 db=$3 p="vps-fixture-$1-$$" hp c f0=$fails
  local -a dc=(docker compose -f fixtures/compose/compose.yaml -f test/fixtures-compose.ci.yaml -p "$p")
  echo "== $name"
  SERVICE_PASSWORD_DB=$(openssl rand -hex 16) || { check "$name: openssl rand" failed ok; return; }
  export SERVICE_PASSWORD_DB
  projects+=("$p")
  local out
  if ! out=$("${dc[@]}" up -d --build --wait --wait-timeout "$WAIT" 2>&1); then
    tail_out "$out"
    check "$name: compose up --wait" failed ok
    "${dc[@]}" logs --tail 30 2>&1 | sed 's/^/     /'
    return
  fi
  echo "ok   $name: compose up --build --wait"
  hp=$("${dc[@]}" port web "$port" | grep -m1 '^127\.0\.0\.1:')
  c=$("${dc[@]}" ps -q web)
  contract "$name" "http://$hp/api/health" 200 ok "$db"
  in_container "$name" "$c" "$port" "$db"
  "${dc[@]}" stop db >/dev/null 2>&1
  contract "$name (db stopped)" "http://$hp/api/health" 503 error error
  [ "$fails" = "$f0" ] || dump_logs "$c"
  unset SERVICE_PASSWORD_DB
}

for t in curl jq openssl docker; do command -v "$t" >/dev/null || { echo "FAIL $t is not installed"; exit 1; }; done
docker compose version >/dev/null 2>&1 || { echo "FAIL docker compose (v2) is not available"; exit 1; }

want=("$@")
[ "${#want[@]}" -gt 0 ] || mapfile -t want < <(cut -d' ' -f1 <<<"$TABLE")
for w in "${want[@]}"; do
  row=$(awk -v w="$w" '$1 == w' <<<"$TABLE")
  if [ -z "$row" ]; then
    echo "FAIL unknown fixture: $w (known: $(cut -d' ' -f1 <<<"$TABLE" | paste -sd' ' -))"
    fails=$((fails + 1)); continue
  fi
  read -r name port db kind dir <<<"$row"
  case $kind in
    dockerfile) run_dockerfile "$name" "$port" "$db" "${dir:-fixtures/$name}" ;;
    compose) run_compose "$name" "$port" "$db" ;;
  esac
done

if [ "$fails" = 0 ]; then echo "ALL FIXTURES OK"; else echo "$fails FIXTURE CHECKS FAILED"; exit 1; fi
