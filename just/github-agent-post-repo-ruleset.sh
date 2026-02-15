#!/usr/bin/env bash
set -euo pipefail

repo="${1:?usage: github-agent-post-repo-ruleset.sh OWNER/REPO}"

ruleset_id=$(
    gh api \
        --method POST \
        -H "Accept: application/vnd.github+json" \
        "/repos/$repo/rulesets" \
        --input - \
        --jq '.id' <<'JSON'
{
  "name": "deny-non-agent-updates",
  "target": "branch",
  "enforcement": "disabled",
  "conditions": {
    "ref_name": {
      "include": ["~ALL"],
      "exclude": ["refs/heads/agent/**"]
    }
  },
  "bypass_actors": [
  ],
  "rules": [
    {"type": "creation"},
    {"type": "update"},
    {"type": "deletion"}
  ]
}
JSON
)

echo "created ruleset id: $ruleset_id"
echo "edit bypass actors and then enable:"
echo "https://github.com/$repo/settings/rules/$ruleset_id"
