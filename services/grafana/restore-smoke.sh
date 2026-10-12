#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 || ${RYRA_GRAFANA_RESTORE_FIXTURE:-} != 1 ]]; then
  echo 'Run only on a disposable native-auth fixture: RYRA_GRAFANA_RESTORE_FIXTURE=1 bash services/grafana/restore-smoke.sh APP_URL ADMIN_JSON' >&2
  exit 2
fi
app=${1%/}
credentials=$2
umask 077
scratch=$(mktemp -d)
uid="ryra-restore-$(basename "$scratch" | tr -cd 'a-zA-Z0-9')"
phase='native administrator login'
server_pid=''
query() {
  fetch "$app/api/datasources/proxy/uid/$uid/api/v1/query?query=vector%281%29" \
    | jq -e '.status == "success"' >/dev/null
}
fetch() {
  curl --silent --show-error --fail-with-body --connect-timeout 10 --max-time 30 \
    --header "@$scratch/auth" "$@"
}
cleanup() {
  smoke_status=$?
  if [[ $smoke_status != 0 ]]; then echo "Grafana restore smoke failed during $phase." >&2; fi
  if [[ -f "$scratch/dashboard-created" ]]; then
    fetch --request DELETE "$app/api/dashboards/uid/$uid" --output /dev/null \
      || echo 'Failed to delete Grafana restore dashboard.' >&2
  fi
  if [[ -f "$scratch/datasource-created" ]]; then
    fetch --request DELETE "$app/api/datasources/uid/$uid" --output /dev/null \
      || echo 'Failed to delete Grafana restore datasource.' >&2
  fi
  if [[ -f "$scratch/marker-created" ]]; then rm -f "/var/lib/grafana/plugins/$uid"; fi
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" || true
    wait "$server_pid" || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT
command -v socat >/dev/null
canary_handler=$(realpath "$(dirname "$0")/datasource-canary.sh")
printf -v canary_command 'bash %q' "$canary_handler"
socat TCP4-LISTEN:19090,bind=127.0.0.1,reuseaddr,fork "SYSTEM:$canary_command" > "$scratch/backend-log" 2>&1 &
server_pid=$!
sleep 1
kill -0 "$server_pid"
jq -er 'select((.username | type == "string") and (.password | type == "string")) |
  "Authorization: Basic " + ((.username + ":" + .password) | @base64)' "$credentials" > "$scratch/auth"
fetch "$app/api/user" > "$scratch/user"
jq -e '.isGrafanaAdmin == true' "$scratch/user" >/dev/null
phase='saved dashboard and datasource'
jq -n --arg uid "$uid" '{dashboard:{uid:$uid,title:"Ryra restore saved",schemaVersion:39,panels:[]},overwrite:false}' > "$scratch/dashboard"
fetch --header 'Content-Type: application/json' --data-binary "@$scratch/dashboard" "$app/api/dashboards/db" > "$scratch/created"
touch "$scratch/dashboard-created"
jq -n --arg uid "$uid" '{uid:$uid,name:$uid,type:"prometheus",access:"proxy",url:"http://127.0.0.1:19090",secureJsonData:{httpHeaderValue1:"restore-canary"},jsonData:{httpHeaderName1:"X-Ryra-Restore"}}' > "$scratch/datasource"
fetch --header 'Content-Type: application/json' --data-binary "@$scratch/datasource" "$app/api/datasources" > "$scratch/created"
touch "$scratch/datasource-created"
query
mkdir -p /var/lib/grafana/plugins
printf 'saved plugin data\n' > "/var/lib/grafana/plugins/$uid"
touch "$scratch/marker-created"
phase='automatic backup hooks'
ryra-backup-grafana backup
ryra-backup-grafana exec snapshots --json > "$scratch/snapshots"
snapshot=$(jq -er 'sort_by(.time) | last | .id' "$scratch/snapshots")
phase='post-backup mutation'
jq '.dashboard.title = "Ryra restore mutated" | .overwrite = true' "$scratch/dashboard" > "$scratch/mutated"
fetch --header 'Content-Type: application/json' --data-binary "@$scratch/mutated" "$app/api/dashboards/db" > "$scratch/updated"
fetch --request DELETE "$app/api/datasources/uid/$uid" --output /dev/null
printf 'mutated plugin data\n' > "/var/lib/grafana/plugins/$uid"
phase='real repository restore'
ryra-backup-grafana restore "$snapshot"
phase='restored native login and content'
fetch "$app/api/user" | jq -e '.isGrafanaAdmin == true' >/dev/null
fetch "$app/api/dashboards/uid/$uid" | jq -e '.dashboard.title == "Ryra restore saved"' >/dev/null
fetch "$app/api/datasources/uid/$uid" | jq -e '.url == "http://127.0.0.1:19090" and .secureJsonFields.httpHeaderValue1 == true' >/dev/null
query
printf 'saved plugin data\n' > "$scratch/marker"
cmp "$scratch/marker" "/var/lib/grafana/plugins/$uid"
echo 'Grafana repository restore recovered native login, dashboard, decrypted datasource credential and plugin data.'
