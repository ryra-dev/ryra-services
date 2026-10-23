set -euo pipefail
if (( $# != 3 )); then
  echo 'Usage: ryra-network-challenge present|cleanup FQDN DIGEST' >&2
  exit 1
fi
action=$1
fqdn=$2
value=$3
case "$action" in
  present|cleanup) ;;
  *) echo "Unknown certificate challenge action: $action" >&2; exit 1 ;;
esac
time=$(date +%s)
signature=$(printf 'ryra-network-challenge\n%s\n%s\n%s\n%s\n' "$action" "$fqdn" "$value" "$time" |
  ssh-keygen -Y sign -q -n ryra-network@ryra.dev -f "${RYRA_NETWORK_HOST_KEY_FILE:?}")
jq -n --arg action "$action" --arg fqdn "$fqdn" --arg value "$value" \
  --argjson time "$time" --arg signature "$signature" \
  '{action: $action, fqdn: $fqdn, value: $value, time: $time, signature: $signature}' |
  curl --fail-with-body --silent --show-error --connect-timeout 10 --max-time 45 \
    -H 'Content-Type: application/json' --data-binary @- \
    "${RYRA_NETWORK_SERVER:?}/v1/network/challenges"
