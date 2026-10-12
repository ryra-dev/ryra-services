#!/usr/bin/env bash
set -euo pipefail
umask 077
state=${AUTH_STATE:?}
mkdir -p "$state/keys" "$state/clients"
chmod 0700 "$state/keys" "$state/clients"
scratch=$(mktemp -d "$state/keys/.new.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

if [[ ! -d "$state/keys/current" ]]; then
  for key in jwt session storage hmac ldap-bind ldap-admin ldap-jwt; do
    openssl rand -hex 32 | tr -d '\n' > "$scratch/$key"
  done
  if ! openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 > "$scratch/signing" 2>/dev/null; then
    echo 'Could not generate the managed OIDC signing key.' >&2
    exit 1
  fi
  printf 'LLDAP_KEY_SEED=' > "$scratch/lldap.env"
  openssl rand -hex 32 >> "$scratch/lldap.env"
  mv "$scratch" "$state/keys/current"
  scratch=$(mktemp -d "$state/keys/.new.XXXXXX")
fi
for key in jwt session storage hmac signing ldap-bind ldap-admin ldap-jwt lldap.env; do
  if [[ ! -s "$state/keys/current/$key" ]]; then
    echo "Managed authentication key $key is missing; restore its backup before starting." >&2
    exit 1
  fi
done

for client in "$@"; do
  if [[ ! "$client" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    echo 'Invalid managed OIDC service name.' >&2
    exit 1
  fi
  if [[ ! -d "$state/clients/$client" ]]; then
    rm -rf "$scratch"
    scratch=$(mktemp -d "$state/clients/.new.XXXXXX")
    if ! authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 64 --random.charset alphanumeric > "$scratch/generated" 2>/dev/null; then
      echo 'Could not generate managed OIDC client credentials.' >&2
      exit 1
    fi
    sed -n 's/^Random Password: //p' "$scratch/generated" > "$scratch/secret"
    sed -n 's/^Digest: //p' "$scratch/generated" > "$scratch/hash"
    if ! { [[ $(wc -l < "$scratch/secret") == 1 && $(wc -l < "$scratch/hash") == 1 ]] &&
      grep -Eq '^[a-zA-Z0-9]{64}$' "$scratch/secret" &&
      grep -Eq '^\$pbkdf2-sha512\$' "$scratch/hash"; }; then
      echo 'Authelia did not return a complete OIDC credential pair.' >&2
      exit 1
    fi
    rm "$scratch/generated"
    mv "$scratch" "$state/clients/$client"
    scratch=$(mktemp -d "$state/clients/.new.XXXXXX")
  fi
  if [[ ! -s "$state/clients/$client/secret" || ! -s "$state/clients/$client/hash" ]]; then
    echo 'Managed OIDC credentials are incomplete; restore their backup before starting.' >&2
    exit 1
  fi
done
