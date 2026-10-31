# Shared jq defs for the just/grafana-*.sh dashboard scripts. Use via
# grafana-lib.sh's "gjq FILTER [JQ ARGS...]", which runs jq w/ this module
# included, ex: gjq spec_of FILE.
#
# Defs only see their input + params, not the caller's --arg globals.

# --- manifests + specs --- #

# Bare v2 dashboard spec of a Git Sync manifest (its `.spec`), or the input
# itself if it's already a bare spec.
def spec_of: if .apiVersion? and .spec? then .spec else . end;

# Git Sync manifest of the input spec w/ dashboard uid `$uid`.
def manifest($uid): {
  apiVersion: "dashboard.grafana.app/v2",
  kind: "Dashboard",
  metadata: {name: $uid},
  spec: .
};

# --- API objects --- #

# Error text of an API response: the `.message` of a k8s Status (or Grafana
# error), else the compact JSON.
def error_message:
  if (.message? // "") != "" then .message else tojson end;

# --- auth --- #

# `Authorization` header line for basic auth `$user` + `$password`.
def basic_auth_header($user; $password):
  "Authorization: Basic \("\($user):\($password)" | @base64)";

# `Authorization` header line for (service account) token `$token`.
def bearer_auth_header($token): "Authorization: Bearer \($token | trim)";
