#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ $# != 3 ]]; then
  printf 'Usage: certificate-check.sh HOST FULLCHAIN KEY\n' >&2
  exit 2
fi
host=$1
fullchain=$2
key=$3

fail() {
  printf 'Ryra certificate check for %s (fullchain: %s, key: %s): %s\n' "$host" "$fullchain" "$key" "$1" >&2
  exit 1
}

trap 'fail "could not complete validation; check file access and that OpenSSL and coreutils are available"' ERR
[[ -n $host ]] || fail "hostname is empty; supply the HTTPS hostname"
for path in "$fullchain" "$key"; do
  [[ -e $path ]] || fail "file is missing: $path; place the PEM file at this path before starting or reloading nginx"
  [[ -f $path ]] || fail "not a regular file: $path; supply a PEM file"
  [[ -r $path ]] || fail "file is not readable: $path; grant nginx read access to the file and search access to its parent directories"
done

mode=$(stat -L -c '%a' -- "$key") || fail "cannot read private key permissions; check access to the key path"
(( (8#$mode & 0026) == 0 )) || fail "private key permissions allow group write or world read/write; use mode 0640 with the nginx group, or 0600 when nginx owns the key"

leaf=
certificate=
while IFS= read -r line || [[ -n $line ]]; do
  line=${line%$'\r'}
  case "$line" in
    '-----BEGIN CERTIFICATE-----')
      [[ -z $certificate ]] || fail "invalid PEM bundle; a certificate is missing its END line"
      certificate="$line"$'\n'
      ;;
    '-----END CERTIFICATE-----')
      [[ -n $certificate ]] || fail "invalid PEM bundle; a certificate is missing its BEGIN line"
      certificate+="$line"$'\n'
      openssl x509 -inform PEM -noout <<< "$certificate" >/dev/null 2>&1 ||
        fail "invalid PEM certificate in the bundle; replace the fullchain with the leaf certificate followed by its intermediate certificates"
      if [[ -z $leaf ]]; then leaf=$certificate; fi
      certificate=
      ;;
    *)
      if [[ -n $certificate ]]; then
        certificate+="$line"$'\n'
      elif [[ -n ${line//[[:space:]]/} ]]; then
        fail "invalid PEM bundle; only certificate blocks and whitespace are allowed"
      fi
      ;;
  esac
done < "$fullchain"
[[ -n $leaf && -z $certificate ]] || fail "empty or incomplete PEM bundle; supply the leaf certificate followed by its intermediate certificates"

leaf_info() {
  openssl x509 -inform PEM -noout "$@" <<< "$leaf" 2>/dev/null
}

start=$(leaf_info -startdate) || fail "cannot read the leaf certificate start date; replace the fullchain"
end=$(leaf_info -enddate) || fail "cannot read the leaf certificate expiry date; replace the fullchain"
start_time=$(date -d "${start#notBefore=}" +%s 2>/dev/null) || fail "invalid leaf certificate start date; replace the fullchain"
end_time=$(date -d "${end#notAfter=}" +%s 2>/dev/null) || fail "invalid leaf certificate expiry date; replace the fullchain"
now=$(date +%s)
(( now >= start_time )) || fail "leaf certificate is not yet valid (${start#notBefore=}); check the machine clock or supply a currently valid certificate"
(( now < end_time )) || fail "leaf certificate has expired (${end#notAfter=}); replace the fullchain and matching key"

# OpenSSL 3.0 returns success from -checkhost even when the hostname does not match.
hostname_result=$(leaf_info -checkhost "$host") || fail "cannot check the certificate hostname; supply a valid HTTPS hostname"
[[ $hostname_result == "Hostname $host does match certificate" ]] ||
  fail "leaf certificate does not cover the hostname; supply a certificate for $host"

while IFS= read -r line || [[ -n $line ]]; do
  case "${line%$'\r'}" in
    *'-----BEGIN ENCRYPTED PRIVATE KEY-----'*|'Proc-Type:'*ENCRYPTED*)
      fail "private key must be unencrypted for unattended nginx startup; supply an unencrypted PEM key with restricted permissions"
      ;;
  esac
done < "$key"
openssl pkey -inform PEM -in "$key" -passin pass: -check -noout >/dev/null 2>&1 ||
  fail "cannot read a valid unencrypted PEM private key; replace the key with the matching unencrypted private key"

certificate_public=$(leaf_info -pubkey) ||
  fail "cannot read the certificate public key; replace the fullchain"
key_public=$(openssl pkey -inform PEM -in "$key" -passin pass: -pubout 2>/dev/null) ||
  fail "cannot read the private key public component; supply the matching unencrypted PEM private key"

normalize_ec_public() {
  openssl pkey -pubin -pubout -ec_conv_form uncompressed -ec_param_enc named_curve 2>/dev/null
}

if [[ $certificate_public != "$key_public" ]]; then
  if ! certificate_public=$(normalize_ec_public <<< "$certificate_public") ||
     ! key_public=$(normalize_ec_public <<< "$key_public") ||
     [[ $certificate_public != "$key_public" ]]; then
    fail "private key does not match the leaf certificate; replace the fullchain and key with a matching pair"
  fi
fi
