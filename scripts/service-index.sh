#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp service-index.json.XXXXXX)"
trap 'rm -f "$temporary"' EXIT
nix eval --json --no-write-lock-file .#index | jq . > "$temporary"
case "${1:-}" in
  --check)
    if ! cmp -s service-index.json "$temporary"; then
      echo 'service-index.json is out of date. Run bash scripts/service-index.sh and commit it with the service definitions.' >&2
      exit 1
    fi
    ;;
  '')
    chmod 644 "$temporary"
    mv "$temporary" service-index.json
    ;;
  *)
    echo 'Usage: bash scripts/service-index.sh [--check]' >&2
    exit 2
    ;;
esac
