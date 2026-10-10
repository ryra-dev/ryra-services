#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 ]]; then
  echo 'Usage: bash scripts/auth-runtime-check.sh EVALUATED_LINKDING_OIDC_SCRIPT' >&2
  exit 2
fi
script=$1
umask 077
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
export CREDENTIALS_DIRECTORY="$scratch/credentials"
export RUNTIME_DIRECTORY="$scratch/runtime"
mkdir "$CREDENTIALS_DIRECTORY" "$RUNTIME_DIRECTORY"
head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '\n=' > "$CREDENTIALS_DIRECTORY/client"
bash "$script"
printf 'OIDC_RP_CLIENT_SECRET=%s\n' "$(cat "$CREDENTIALS_DIRECTORY/client")" > "$scratch/expected"
cmp -s "$scratch/expected" "$RUNTIME_DIRECTORY/environment"
[[ "$(stat -c %a "$RUNTIME_DIRECTORY/environment")" == 600 ]]
printf 'interrupted partial write\n' > "$RUNTIME_DIRECTORY/environment.new"
bash "$script"
cmp -s "$scratch/expected" "$RUNTIME_DIRECTORY/environment"
[[ ! -e "$RUNTIME_DIRECTORY/environment.new" ]]
: > "$CREDENTIALS_DIRECTORY/client"
if bash "$script" > "$scratch/refusal" 2>&1; then
  echo 'Empty OIDC credential unexpectedly accepted.' >&2
  exit 1
fi
cmp -s "$scratch/expected" "$RUNTIME_DIRECTORY/environment"
echo 'Runtime OIDC secret loading, interrupted-write retry and empty-secret refusal passed.'
