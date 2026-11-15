# shellcheck shell=bash
#
# grafana-git-sync-setup: create or update Grafana's Git Sync Repository via
# its provisioning API, queue a startup pull, and set the org home
# dashboard. Idempotent; runs after every grafana.service start.
#
# Wrapped by `writeShellApplication` in ./grafana.nix (shebang, strict
# mode, PATH w/ coreutils + curl + jq).
#
# Inputs, from the unit environment:
# - GRAFANA_URL: base URL, ex: http://127.0.0.1:3000
# - GRAFANA_HOST: Host header to send, or "" for none
# - GRAFANA_ADMIN_USER: admin login
# - REPO_NAME: Repository metadata.name
# - REPO_MANIFEST: Repository JSON file, w/o secure values
# - HOME_DASHBOARD: dashboard uid for the org home dashboard, or ""
# - CREDENTIALS_DIRECTORY: systemd credentials: `admin-password`, and
#   `token` (if the repository needs one)

base_url=$GRAFANA_URL
api_url="$base_url/apis/provisioning.grafana.app/v0alpha1"
repos_url="$api_url/namespaces/default/repositories"
host=$GRAFANA_HOST
admin_user=$GRAFANA_ADMIN_USER
name=$REPO_NAME
manifest=$REPO_MANIFEST
home_uid=$HOME_DASHBOARD
creds=$CREDENTIALS_DIRECTORY

umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Basic auth header for the Grafana admin. Grafana trims whitespace
# from `$__file{}` secrets, so trim here too.
jq --null-input --raw-output \
  --arg user "$admin_user" \
  --rawfile password "$creds/admin-password" \
  '"Authorization: Basic " + ("\($user):\($password | trim)" | @base64)' \
  > "$tmp/auth-header"

# api METHOD URL [BODY_FILE]
#
# Send an authenticated request to Grafana. Prints the HTTP status
# ("000" if the connection failed). Response body goes to $tmp/resp.
api() {
  local method=$1 url=$2 body=${3:-}
  local args=(
    --silent --show-error
    --request "$method"
    --header @"$tmp/auth-header"
    --output "$tmp/resp"
    --write-out '%{http_code}'
  )
  if [[ -n $host ]]; then
    args+=(--header "Host: $host")
  fi
  if [[ -n $body ]]; then
    args+=(--header "Content-Type: application/json")
    args+=(--data-binary @"$body")
  fi
  rm -f "$tmp/resp"
  curl "${args[@]}" "$url" || true
}

# die_http WHAT STATUS
#
# Log a failed request w/ its response body, then exit non-zero.
die_http() {
  echo "error: $1: HTTP $2" >&2
  if [[ -f $tmp/resp ]]; then
    cat "$tmp/resp" >&2
    echo >&2
  fi
  exit 1
}

# wait_for_200 URL
#
# Poll until GET URL returns 200, for up to ~1 min. grafana.service is
# Type=simple, so it may still be starting (DB migrations, slow under
# load) or not have registered its k8s-style APIs yet.
wait_for_200() {
  local status=000
  for _ in $(seq 60); do
    status=$(api GET "$1" 2>/dev/null)
    if [[ $status == 200 ]]; then
      return 0
    fi
    sleep 1
  done
  die_http "timed out waiting for GET $1" "$status"
}

echo "waiting for grafana at $base_url"
wait_for_200 "$base_url/api/health"
wait_for_200 "$api_url"

# Request body: the static manifest + the token credential (if any)
if [[ -e $creds/token ]]; then
  jq --rawfile token "$creds/token" '
    ($token | trim) as $token
    | if $token == "" then error("token credential is empty") end
    | .secure.token.create = $token
  ' "$manifest" > "$tmp/body.json"
else
  cp "$manifest" "$tmp/body.json"
fi

# Create or replace the Repository. Re-sending the token on every run
# makes token rotation a restart: Grafana swaps in a new secure value
# and deletes the old one. The PUT omits metadata.resourceVersion, an
# unconditional update (Grafana's generic registry strategy sets
# AllowUnconditionalUpdate). Status is preserved server-side.
status=$(api GET "$repos_url/$name")
case $status in
  404)
    status=$(api POST "$repos_url" "$tmp/body.json")
    [[ $status == 2?? ]] || die_http "create repository $name" "$status"
    echo "created repository $name"
    ;;
  200)
    status=$(api PUT "$repos_url/$name" "$tmp/body.json")
    [[ $status == 2?? ]] || die_http "update repository $name" "$status"
    echo "updated repository $name"
    ;;
  *)
    die_http "get repository $name" "$status"
    ;;
esac

# wait_for_repo_ready
#
# Poll until the controller has reconciled the current spec and the
# repository is healthy, for up to ~1 min. Jobs need a healthy
# repository. After an update, the stored health is stale until the
# controller observes the new generation and re-runs its health check.
wait_for_repo_ready() {
  local status=000
  for _ in $(seq 60); do
    status=$(api GET "$repos_url/$name")
    if [[ $status == 200 ]] && jq -e '
      .metadata.generation == .status.observedGeneration
      and .status.health.healthy == true
    ' "$tmp/resp" > /dev/null; then
      return 0
    fi
    sleep 1
  done
  if [[ $status != 200 ]]; then
    die_http "get repository $name" "$status"
  fi
  echo "error: timed out waiting for repository $name to turn healthy" >&2
  jq -c '
    {generation: .metadata.generation}
    + (.status | {observedGeneration})
    + (.status.health | {healthy, error, message})
  ' "$tmp/resp" >&2
  exit 1
}

# Grafana never syncs a repository on startup. Its controller only pulls
# once `intervalSeconds` passed since the last sync, the spec changed,
# or the repository recovered from unhealthy. A webhook only covers
# pushes while Grafana runs, so a push made while Grafana was down would
# wait up to a full poll interval. Instead, queue one incremental pull
# (a no-op if the branch didn't move) on every start.
# See: pkg/registry/apis/provisioning/controller/repository.go
echo "waiting for repository $name to turn healthy"
wait_for_repo_ready
echo '{"action":"pull","pull":{"incremental":true}}' > "$tmp/pull.json"

# A repository has at most one sync job, named `<name>-sync`, so this
# fails w/ 409 AlreadyExists while another is queued or running, ex: the
# controller's full sync after a spec change (incl. every token
# re-send) or one left over from a crash. That sync covers the startup
# pull, so treat it as done rather than racing it.
status=$(api POST "$repos_url/$name/jobs" "$tmp/pull.json")
if [[ $status == 2?? ]]; then
  echo "triggered pull job for repository $name"
elif [[ $status == 409 ]] \
  && jq -e '.reason == "AlreadyExists"' "$tmp/resp" > /dev/null; then
  echo "sync job already queued for repository $name"
else
  die_http "trigger pull job for repository $name" "$status"
fi

# Org home dashboard. PATCH only sets this preference, unlike PUT,
# which resets the omitted ones (theme, timezone). Grafana stores the
# uid as is: no need to wait for the pull to sync the dashboard.
if [[ -n $home_uid ]]; then
  jq --null-input --arg uid "$home_uid" \
    '{homeDashboardUID: $uid}' > "$tmp/prefs.json"
  status=$(api PATCH "$base_url/api/org/preferences" "$tmp/prefs.json")
  [[ $status == 2?? ]] \
    || die_http "set home dashboard $home_uid" "$status"
  echo "set org home dashboard to $home_uid"
fi
