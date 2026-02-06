#!/usr/bin/env nix
#!nix shell nixpkgs#curl nixpkgs#bash --command bash
# shellcheck shell=bash

set -euo pipefail

GCS_BUCKET="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
VERSION="$(curl -fsSL "$GCS_BUCKET/latest")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
curl -fsSL "$GCS_BUCKET/$VERSION/manifest.json" -o "$SCRIPT_DIR/manifest.json"
