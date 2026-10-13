#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

fail() { printf 'Ryra Cloudflare: %s\n' "$*" >&2; exit 1; }
[[ $# == 3 ]] || fail 'Expected a manifest, state directory and runtime directory.'
manifest=$1
state=$2
runtime=$3
account=${CLOUDFLARE_ACCOUNT_ID:-}
api_token=${CLOUDFLARE_API_TOKEN:-}
unset CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN
api_url=${RYRA_CLOUDFLARE_API_URL:-https://api.cloudflare.com/client/v4}
[[ $api_url == https://api.cloudflare.com/client/v4 || $api_url =~ ^http://127\.0\.0\.1:[0-9]{1,5}$ ]] || fail 'The API must be Cloudflare or a loopback HTTP fixture.'
[[ $state == /* && $runtime == /* && $state != / && $runtime != / ]] || fail 'Use absolute private state and runtime directories.'
mkdir -p "$state/claims" "$runtime"
chmod 700 "$state" "$state/claims" "$runtime"
exec 9>"$state/lock"
flock -w 5 9 || fail 'Another setup is running. Retry when it finishes.'
scratch=$(mktemp -d "$runtime/setup.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 1' HUP INT TERM

jq -e '
  def dnsname: type == "string" and length <= 253 and
    test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$") and
    (split(".") | all(length <= 63));
  def domain: dnsname and
    (test("^[0-9]+(\\.[0-9]+){3}$|\\.(localhost|local|invalid|ts\\.net)$") | not);
  type == "object" and (.provider | type == "string" and test("^[a-z0-9_-]+/[a-z0-9_-]+$")) and
  (.sites | type == "array" and length <= 32 and
    all(.domain | domain) and
    all(.hostName | dnsname) and
    all(.port | type == "number" and floor == . and . >= 1 and . <= 65535) and
    ([.[].domain] | length == (unique | length)))
' "$manifest" >/dev/null || fail 'Invalid gateway manifest. Use unique DNS names and valid loopback ports.'
provider=$(jq -r '.provider' "$manifest")
shopt -s nullglob
claims=("$state"/claims/*.json)
if [[ $(jq '.sites | length' "$manifest") == 0 && ${#claims[@]} == 0 ]]; then
  printf 'Ryra Cloudflare: no owned gateways remain.\n'
  exit 0
fi
[[ $account =~ ^[a-f0-9]{32}$ ]] || fail 'The connection needs a Cloudflare Account ID.'
[[ $api_token =~ ^[A-Za-z0-9_-]{1,512}$ ]] || fail 'The connection needs a Cloudflare API token.'

api() {
  local method=$1 path=$2 body=${3:-} status
  (( SECONDS < 240 )) || fail 'Setup exceeded four minutes. Retry to continue from provider state.'
  local args=(--silent --connect-timeout 5 --max-time 20 --max-filesize 2097152
    --request "$method" --output "$scratch/response" --write-out '%{http_code}'
    --header 'Content-Type: application/json')
  [[ -z $body ]] || args+=(--data-binary "@$body")
  # curl reads authorization from stdin so credentials never enter its arguments.
  if ! status=$(printf 'header = "Authorization: Bearer %s"\n' "$api_token" |
    curl --disable --config - "${args[@]}" "$api_url$path"); then
    fail "Cloudflare $method failed in transport. Retry to re-read its result."
  fi
  [[ $status =~ ^2[0-9][0-9]$ ]] || fail "Cloudflare $method returned HTTP $status. Check connection permissions and retry."
  jq -e '.success == true' "$scratch/response" >/dev/null || fail "Cloudflare $method did not succeed. Review the account and retry."
}

list() {
  local path=$1 page=1 count total collected=0
  printf '[]' >"$scratch/list"
  while (( page <= 40 )); do
    api GET "$path&per_page=50&page=$page"
    jq -e '.result | type == "array"' "$scratch/response" >/dev/null || fail 'Cloudflare returned an invalid list.'
    count=$(jq '.result | length' "$scratch/response")
    total=$(jq -r '.result_info.total_count // -1' "$scratch/response")
    [[ $total =~ ^-?[0-9]+$ ]] || fail 'Cloudflare returned an invalid page count.'
    jq -s '.[0] + .[1].result' "$scratch/list" "$scratch/response" >"$scratch/next"
    mv "$scratch/next" "$scratch/list"
    collected=$((collected + count))
    if (( total >= 0 && collected >= total )); then return; fi
    if (( count < 50 )); then
      (( total < 0 )) || fail 'Cloudflare returned an incomplete list. Retry before changing resources.'
      return
    fi
    page=$((page + 1))
  done
  fail 'Cloudflare lookup exceeded 2000 records. Narrow the connection scope before retrying.'
}

key_for() { printf '%s\n%s' "$provider" "$1" | sha256sum | cut -d' ' -f1; }
load_claim() {
  local file=$1
  jq -e --arg provider "$provider" --arg account "$account" '
    .provider == $provider and .account == $account and
    (.zone | test("^[a-f0-9]{32}$")) and (.domain | test("^[a-z0-9.-]+$")) and
    (.hostName | test("^[a-z0-9.-]+$")) and (.tunnelName | test("^ryra-[a-f0-9]{32}-[a-f0-9]{32}$"))
  ' "$file" >/dev/null || fail 'Ownership state does not match this connection. Drain it with the original provider and account first.'
  domain=$(jq -r '.domain' "$file")
  host_name=$(jq -r '.hostName' "$file")
  zone=$(jq -r '.zone' "$file")
  tunnel_name=$(jq -r '.tunnelName' "$file")
  key=$(key_for "$domain")
  [[ $file == "$state/claims/$key.json" && $tunnel_name == "ryra-$owner-${key:0:32}" ]] || fail 'Ownership state has an unexpected resource name.'
  comment="Ryra:$tunnel_name"
}

find_tunnel() {
  list "/accounts/$account/cfd_tunnel?name=$tunnel_name&is_deleted=false"
  jq --arg name "$tunnel_name" '[.[] | select(.name == $name and .deleted_at == null)]' "$scratch/list" >"$scratch/tunnels"
  local count
  count=$(jq 'length' "$scratch/tunnels")
  (( count <= 1 )) || fail "More than one tunnel claims $domain. Review ownership before retrying."
  tunnel_id=''
  if (( count == 1 )); then
    jq -e --arg account "$account" '.[0] | .account_tag == $account and .config_src == "cloudflare" and
      (.id | test("^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$"))' "$scratch/tunnels" >/dev/null || fail "Tunnel ownership conflicts with $domain."
    tunnel_id=$(jq -r '.[0].id' "$scratch/tunnels")
  fi
}

check_config() {
  api GET "/accounts/$account/cfd_tunnel/$tunnel_id/configurations"
  jq -e --arg domain "$domain" --arg host "$host_name" '
    .result.config | if . == null then true else
      del(.originRequest | select(. == {})) |
      del(."warp-routing" | select(. == {enabled:false})) |
      (if .ingress then .ingress |= map(del(.originRequest | select(. == {}))) else . end) |
      . == {} or . == {ingress:[{service:"http_status:404"}]} or
      (keys == ["ingress"] and
         (.ingress | length == 2 and
          (.[0] | keys == ["hostname","originRequest","service"] and .hostname == $domain and
            .originRequest == {httpHostHeader:$host} and (.service | test("^http://127\\.0\\.0\\.1:[0-9]{1,5}$"))) and
          .[1] == {service:"http_status:404"}))
    end
  ' "$scratch/response" >/dev/null || fail "Tunnel configuration for $domain contains foreign routes or settings. Review it before retrying."
}

find_dns() {
  list "/zones/$zone/dns_records?name=$domain"
  jq --arg domain "$domain" '[.[] | select(.name == $domain)]' "$scratch/list" >"$scratch/dns"
  local count
  count=$(jq 'length' "$scratch/dns")
  (( count <= 1 )) || fail "DNS for $domain has multiple records. Refusing to replace them."
  dns_id=''
  if (( count == 1 )); then
    [[ -n $tunnel_id ]] || fail "DNS for $domain already exists without this machine's tunnel. Refusing to adopt it."
    jq -e --arg comment "$comment" --arg content "$tunnel_id.cfargotunnel.com" '
      .[0] | .comment == $comment and .type == "CNAME" and .content == $content and .proxied == true and
      (.id | test("^[a-f0-9]{32}$"))
    ' "$scratch/dns" >/dev/null || fail "DNS for $domain is not this machine's owned proxied tunnel record. Refusing to overwrite it."
    dns_id=$(jq -r '.[0].id' "$scratch/dns")
  fi
}

resolve_zone() {
  local candidate=$domain
  while [[ $candidate == *.* ]]; do
    list "/zones?account.id=$account&name=$candidate"
    jq --arg name "$candidate" '[.[] | select(.name == $name)]' "$scratch/list" >"$scratch/zones"
    if [[ $(jq 'length' "$scratch/zones") != 0 ]]; then
      jq -e --arg account "$account" 'length == 1 and (.[0] | .account.id == $account and
        .status == "active" and .type == "full" and (.id | test("^[a-f0-9]{32}$")))' "$scratch/zones" >/dev/null || fail "The zone for $domain must be active, full and in this account."
      zone=$(jq -r '.[0].id' "$scratch/zones")
      [[ $domain == "$candidate" || ${domain%."$candidate"} != *.* ]] || fail "Automatic edge HTTPS covers only the zone apex and one subdomain label: $domain needs a separate certificate configuration."
      api GET "/zones/$zone/ssl/universal/settings"
      jq -e '.result.enabled == true' "$scratch/response" >/dev/null || fail "Enable Universal SSL for $candidate before publishing $domain."
      api GET "/zones/$zone/settings/ssl"
      jq -e '.result.value | . == "flexible" or . == "full" or . == "strict" or . == "origin_pull"' "$scratch/response" >/dev/null || fail "Enable edge HTTPS for $candidate before publishing $domain."
      return
    fi
    candidate=${candidate#*.}
  done
  fail "No accessible Cloudflare zone owns $domain. Grant Zone Read and DNS Edit for its zone."
}

if [[ ! -e $state/owner ]]; then
  pending=$(mktemp "$state/.owner.XXXXXXXX")
  tr -d '-' </proc/sys/kernel/random/uuid >"$pending"
  sync -f "$pending"
  mv "$pending" "$state/owner"
  sync -f "$state"
fi
owner=$(cat "$state/owner")
[[ $owner =~ ^[a-f0-9]{32}$ ]] || fail 'Invalid machine ownership ID. Preserve the state directory and review its backup.'

# Validate all desired sites before creating any provider resource.
while IFS= read -r site; do
  domain=$(jq -r '.domain' <<<"$site")
  host_name=$(jq -r '.hostName' <<<"$site")
  key=$(key_for "$domain")
  resolve_zone
  claim="$state/claims/$key.json"
  if [[ -e $claim ]]; then
    expected_zone=$zone
    expected_host=$host_name
    load_claim "$claim"
    [[ $zone == "$expected_zone" && $host_name == "$expected_host" ]] || fail "The zone or backend host for $domain changed. Drain the old route first."
  else
    tunnel_name="ryra-$owner-${key:0:32}"
    comment="Ryra:$tunnel_name"
  fi
  find_tunnel
  if [[ ! -e $claim && -n $tunnel_id ]]; then fail "An unclaimed tunnel already uses $domain's ownership name. Refusing to adopt it."; fi
  [[ -z $tunnel_id ]] || check_config
  find_dns
  if [[ ! -e $claim ]]; then
    pending=$(mktemp "$state/claims/.claim.XXXXXXXX")
    jq -n --arg provider "$provider" --arg account "$account" --arg domain "$domain" --arg zone "$zone" \
      --arg hostName "$host_name" --arg tunnelName "$tunnel_name" \
      '{provider:$provider,account:$account,domain:$domain,zone:$zone,hostName:$hostName,tunnelName:$tunnelName}' >"$pending"
    sync -f "$pending"
    mv "$pending" "$claim"
    sync -f "$state/claims"
  fi
done < <(jq -c '.sites[]' "$manifest")

for claim in "$state"/claims/*.json; do
  load_claim "$claim"
  if jq -e --arg domain "$domain" '.sites | any(.domain == $domain)' "$manifest" >/dev/null; then continue; fi
  rm -f -- "$runtime/$key.token"
  find_tunnel
  [[ -z $tunnel_id ]] || check_config
  find_dns
  if [[ -n $tunnel_id ]]; then
    printf '{"config":{"ingress":[{"service":"http_status:404"}],"warp-routing":{"enabled":false}}}' >"$scratch/body"
    api PUT "/accounts/$account/cfd_tunnel/$tunnel_id/configurations" "$scratch/body"
  fi
  if [[ -n $dns_id ]]; then api DELETE "/zones/$zone/dns_records/$dns_id"; fi
  # Cloudflare refuses active tunnels. Keep the claim until a later retry can delete it.
  if [[ -n $tunnel_id ]]; then api DELETE "/accounts/$account/cfd_tunnel/$tunnel_id"; fi
  rm -- "$claim"
  sync -f "$state/claims"
  printf 'Ryra Cloudflare: removed %s.\n' "$domain"
done

while IFS= read -r site; do
  domain=$(jq -r '.domain' <<<"$site")
  port=$(jq -r '.port' <<<"$site")
  load_claim "$state/claims/$(key_for "$domain").json"
  find_tunnel
  find_dns
  if [[ -z $tunnel_id ]]; then
    jq -n --arg name "$tunnel_name" '{name:$name,config_src:"cloudflare"}' >"$scratch/body"
    api POST "/accounts/$account/cfd_tunnel" "$scratch/body"
    find_tunnel
    [[ -n $tunnel_id ]] || fail "Created tunnel for $domain is not visible yet. Retry setup."
  fi
  check_config
  jq -n --arg domain "$domain" --arg host "$host_name" --arg backend "http://127.0.0.1:$port" \
    '{config:{ingress:[{hostname:$domain,service:$backend,originRequest:{httpHostHeader:$host}},
      {service:"http_status:404"}],"warp-routing":{enabled:false}}}' >"$scratch/body"
  api PUT "/accounts/$account/cfd_tunnel/$tunnel_id/configurations" "$scratch/body"
  api GET "/accounts/$account/cfd_tunnel/$tunnel_id/token"
  jq -er '.result | select(type == "string" and length > 0 and test("^[A-Za-z0-9_+/=-]+$"))' "$scratch/response" >"$scratch/token" || fail 'Cloudflare did not return a valid tunnel token.'
  mv "$scratch/token" "$runtime/$key.token"
  chmod 600 "$runtime/$key.token"
  find_dns
  if [[ -z $dns_id ]]; then
    jq -n --arg name "$domain" --arg content "$tunnel_id.cfargotunnel.com" --arg comment "$comment" \
      '{type:"CNAME",name:$name,content:$content,proxied:true,ttl:1,comment:$comment}' >"$scratch/body"
    api POST "/zones/$zone/dns_records" "$scratch/body"
    find_dns
    [[ -n $dns_id ]] || fail "Created DNS for $domain is not visible yet. Retry setup."
  fi
  printf 'Ryra Cloudflare: configured %s.\n' "$domain"
done < <(jq -c '.sites[]' "$manifest")
