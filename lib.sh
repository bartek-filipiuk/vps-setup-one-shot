# Shared helpers for verify.sh and the phase files. Source it: `. ./lib.sh`
# Agent shells lose functions and variables between calls (the working directory may
# persist), so phase commands start with `. ./lib.sh;` and never `cd` outside a subshell.

# VPS_STATE can be pointed at another file (PREPARE-APP uses the app's .coolify.env);
# the server itself is always looked up in the global setup state.
VPS_SETUP_STATE="$HOME/.config/vps-setup/state"
VPS_STATE="${VPS_STATE:-$VPS_SETUP_STATE}"
COOLIFY_CONFIG="$HOME/.config/coolify/config"

# --- state: KEY=VALUE lines, only things that cannot be derived from reality ---

state_get() { [ -f "$VPS_STATE" ] && grep -m1 "^$1=" "$VPS_STATE" | cut -d= -f2-; }

state_set() {
  mkdir -p "$(dirname "$VPS_STATE")"
  ( umask 077; touch "$VPS_STATE"
    { grep -v "^$1=" "$VPS_STATE" || true; printf '%s=%s\n' "$1" "$2"; } > "$VPS_STATE.tmp" ) &&
  mv "$VPS_STATE.tmp" "$VPS_STATE"
}

# --- remote shell on the VPS (never run server commands without this) ---

rssh() {
  local ip; ip=$(grep -m1 '^VPS_IP=' "$VPS_SETUP_STATE" 2>/dev/null | cut -d= -f2-)
  [ -n "$ip" ] || { echo "VPS_IP not set in $VPS_SETUP_STATE" >&2; return 1; }
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "root@$ip" "$@"
}

# --- Coolify API ---

# Config values are read with grep, not sourced: tokens contain '|'.
coolify_get() { [ -f "$COOLIFY_CONFIG" ] && grep -m1 "^$1=" "$COOLIFY_CONFIG" | cut -d= -f2-; }

# Server uuid: from the config when phase 04 wrote it, otherwise the first server from the API
# (configs written by other tools often lack it).
coolify_server() {
  local s; s=$(coolify_get COOLIFY_SERVER_UUID)
  [ -n "$s" ] && echo "$s" || capi GET /servers | jq -r '.[0].uuid // empty'
}

# capi METHOD /path [json-body] -> prints body; returns 1 and prints body to stderr on HTTP >= 400.
# Each call gives up after CAPI_MAX_TIME seconds (default 30).
capi() {
  local url token out code
  url=$(coolify_get COOLIFY_URL); token=$(coolify_get COOLIFY_TOKEN)
  [ -n "$url" ] && [ -n "$token" ] || { echo "Coolify config missing in $COOLIFY_CONFIG" >&2; return 1; }
  # The body goes through stdin, not argv, so keys and passwords never show up in `ps`.
  out=$(printf '%s' "${3:-}" | curl -sS --max-time "${CAPI_MAX_TIME:-30}" -w '\n%{http_code}' -X "$1" "$url/api/v1$2" \
    -H "Authorization: Bearer $token" -H "Accept: application/json" \
    -H "Content-Type: application/json" ${3:+--data-binary @-}) || return 1
  code=${out##*$'\n'}; out=${out%$'\n'*}
  if [ "$code" -ge 400 ]; then echo "HTTP $code $1 $2: $out" >&2; return 1; fi
  printf '%s\n' "$out"
}

# deploy_and_wait APP_UUID -> triggers a deploy, polls ~15 min, prints log tail on failure.
deploy_and_wait() {
  local res dep status i poll=${DEPLOY_POLL_SECONDS:-10}
  res=$(capi POST "/deploy?uuid=$1") || return 1  # GET returns 405 since Coolify 4.3
  dep=$(jq -r '.deployments[0].deployment_uuid // .deployment_uuid // empty' <<<"$res")
  [ -n "$dep" ] || { echo "No deployment uuid in: $res" >&2; return 1; }
  echo "deployment $dep queued"
  for i in $(seq 1 90); do
    sleep "$poll"
    status=$(capi GET "/deployments/$dep" | jq -r '.status // "unknown"')
    echo "[$((i * poll))s] $status"
    case "$status" in
      finished) return 0 ;;
      failed|cancelled*) deploy_logs "$dep"; return 1 ;;
    esac
  done
  echo "Timed out after 15 min; deployment $dep still $status" >&2
  return 1
}

# deploy_logs DEPLOYMENT_UUID -> last 60 visible build log lines.
deploy_logs() {
  capi GET "/deployments/$1" |
    jq -r '(.logs // "[]") | (fromjson? // []) | .[] | select(.hidden != true) | .output' |
    tail -60
}
