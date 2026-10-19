#!/usr/bin/env bash
# Builds every fixture in fixtures/ with Docker and checks the health contract: 200
# {"status":"ok","db":<expected>} on 127.0.0.1, the same answer on [::1] inside the container,
# the image's HEALTHCHECK passing, a non-root user, and for fixtures with a database 503
# {"status":"error","db":"error"} once the database is stopped. No server; needs Docker with
# a recent compose v2 (up --wait --wait-timeout), curl, jq and openssl.
# Everything it creates is named vps-fixture-<name>-<pid> and removed by that name on exit;
# nothing is pruned. The Postgres password comes from openssl rand and goes through the
# environment, never argv.
# Usage: bash test/fixtures.sh [static|python-fastapi|go|compose ...]   (prints ALL FIXTURES OK)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# name port db kind
TABLE='static 8080 none dockerfile
python-fastapi 8000 ok dockerfile
go 8080 ok dockerfile
compose 8080 ok compose'
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
  user=$(docker inspect -f '{{.Config.User}}' "$c")
  case $user in ''|root|0|0:*|root:*) check "$name: runs as a non-root user" "${user:-<empty>}" "<non-root>" ;;
    *) check "$name: runs as a non-root user" non-root non-root ;; esac
}

# tail_out TEXT: the last 40 lines of a failed build or compose up, indented
tail_out() { tail -n 40 <<<"$1" | sed 's/^/     /'; }

dump_logs() { echo "     logs of $1:"; docker logs --tail 30 "$1" 2>&1 | sed 's/^/     /'; }

run_dockerfile() {
  local name=$1 port=$2 db=$3 n="vps-fixture-$1-$$" hp f0=$fails
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
  if ! out=$(docker build -t "$n" "fixtures/$name" 2>&1); then
    tail_out "$out"; check "$name: docker build" failed ok; return
  fi
  images+=("$n")
  echo "ok   $name: docker build"
  if [ "$db" = ok ]; then
    local i
    for ((i = 0; i < WAIT; i++)); do docker exec "$n-db" pg_isready -q -h 127.0.0.1 -U app -d app && break; sleep 1; done
    containers+=("$n")
    docker run -d --name "$n" --network "$n" -p "127.0.0.1::$port" -e DATABASE_URL "$n" >/dev/null
  else
    containers+=("$n")
    docker run -d --name "$n" --network "$n" -p "127.0.0.1::$port" "$n" >/dev/null
  fi
  hp=$(docker port "$n" "$port/tcp" | grep -m1 '^127\.0\.0\.1:')
  contract "$name" "http://$hp/api/health" 200 ok "$db"
  in_container "$name" "$n" "$port" "$db"
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
  read -r name port db kind <<<"$row"
  case $kind in
    dockerfile) run_dockerfile "$name" "$port" "$db" ;;
    compose) run_compose "$name" "$port" "$db" ;;
  esac
done

if [ "$fails" = 0 ]; then echo "ALL FIXTURES OK"; else echo "$fails FIXTURE CHECKS FAILED"; exit 1; fi
