#!/usr/bin/env bash
set -euo pipefail

# Filter out current branch and master/main branches
CURRENT_BRANCH="$(git branch --show-current --format='%(refname:short)')"
JQ_SELECT_BRANCH_NAME=".branch != \"master\" and .branch != \"main\" and .branch != \"$CURRENT_BRANCH\""

# By default, branches with no upstream are considered "merged"
JQ_SELECT="select($JQ_SELECT_BRANCH_NAME and .upstream == \"\") | .branch"
if [[ "$@" == "-a" || "$@" == "--all" ]]; then
  JQ_SELECT="select($JQ_SELECT_BRANCH_NAME) | .branch"
fi

TEMPFILE=$(mktemp)
trap 'rm $TEMPFILE' EXIT

# List the selected branches and open them in an editor first to
# interactively choose which to delete.
git branch --list --format='{"branch":"%(refname:short)","upstream":"%(upstream)"}' \
  | jq -r "$JQ_SELECT" > $TEMPFILE
$EDITOR $TEMPFILE
xargs git branch --delete --force < $TEMPFILE
