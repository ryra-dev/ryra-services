#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 5 ]]; then
  echo 'Usage: bash scripts/auth-smoke.sh ISSUER APP_URL nextcloud|linkding|grafana|forgejo CREDENTIALS_JSON EXPECTED_USER' >&2
  exit 2
fi
issuer=${1%/}
app=${2%/}
kind=$3
credentials=$4
expected_user=$5
case "$kind" in nextcloud|linkding|grafana|forgejo) ;; *) echo 'Unsupported auth smoke service.' >&2; exit 2 ;; esac
[[ "$issuer" == https://* && "$app" == https://* ]] || { echo 'Auth smoke requires stable HTTPS origins.' >&2; exit 2; }
umask 077
scratch=$(mktemp -d)
phase='provider discovery'
cleanup() {
  smoke_status=$?
  if [[ "$smoke_status" != 0 ]]; then echo "Auth smoke failed during $phase." >&2; fi
  if [[ "$smoke_status" != 0 && -f "$scratch/approved" ]]; then
    grep -oE 'CSRF check failed|Password confirmation required|State token missing|State token does not match|Your login token is invalid or has expired' "$scratch/approved" >&2 || true
  fi
  if [[ -f "$scratch/dav-auth" && -f "$scratch/canary-url" ]]; then
    curl --silent --show-error --fail --proto '=https' --connect-timeout 10 --max-time 30 \
      --header "@$scratch/dav-auth" --config "$scratch/canary-url" --request DELETE --output /dev/null \
      || echo 'Failed to clean up the DAV smoke canary.' >&2
  fi
  if [[ -f "$scratch/dav-auth" ]]; then
    curl --silent --show-error --fail --proto '=https' --connect-timeout 10 --max-time 30 \
      --header "@$scratch/dav-auth" --header 'OCS-APIRequest: true' --request DELETE \
      "$app/ocs/v2.php/core/apppassword" --output /dev/null \
      || echo 'Failed to revoke the login-v2 smoke app password.' >&2
  fi
  if [[ -f "$scratch/bookmark-id" && -f "$scratch/linkding-auth" ]]; then
    client_fetch --header "@$scratch/linkding-auth" --request DELETE \
      "$app/api/bookmarks/$(cat "$scratch/bookmark-id")/" --output /dev/null \
      || echo 'Failed to delete the Linkding smoke bookmark.' >&2
  fi
  if [[ -f "$scratch/delete-token-body" ]]; then
    fetch --header "@$scratch/linkding-csrf" --referer "$app/settings/integrations" \
      --data-binary "@$scratch/delete-token-body" "$app/settings/integrations/delete-api-token" --output /dev/null \
      || echo 'Failed to revoke the Linkding smoke API token.' >&2
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT
jar="$scratch/cookies"
client_fetch() {
  curl --silent --show-error --fail-with-body --connect-timeout 10 --max-time 60 \
    --proto '=https' --proto-redir '=https' "$@"
}
fetch() {
  client_fetch --cookie "$jar" --cookie-jar "$jar" "$@"
}
authorize() {
  fetch --location --output "$scratch/application" --write-out '%{url_effective}' "$1" > "$scratch/final-url" || return 1
  if jq -eR --arg app "$app" 'startswith($app + "/")' "$scratch/final-url" >/dev/null; then
    return
  fi
  phase='explicit synthetic OIDC consent'
  jq -eR --arg issuer "$issuer" '
    select(startswith($issuer + "/consent/openid/decision?")) |
    split("?")[1] | split("&") | map(split("=")) |
    select(length == 2 and all(.[]; length == 2)) |
    select((map(.[0]) | sort) == ["flow", "flow_id"]) |
    map({key:.[0],value:.[1]}) | from_entries |
    select(.flow == "openid_connect" and
      (.flow_id | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))) |
    .flow_id' "$scratch/final-url" > "$scratch/flow-id.json" || return 1
  jq -r --arg issuer "$issuer" '"url = " + ($issuer + "/api/oidc/consent?flow_id=" + . | tojson)' \
    "$scratch/flow-id.json" > "$scratch/consent-url" || return 1
  fetch --config "$scratch/consent-url" > "$scratch/consent" || return 1
  scopes='["openid","profile","email","groups"]'
  if [[ "$kind" == linkding ]]; then scopes='["openid","profile","email"]'; fi
  jq -e --arg client "ryra-$kind" --argjson scopes "$scopes" '
    .status == "OK" and .data.client_id == $client and
    (.data.scopes | sort) == ($scopes | sort) and .data.require_login == false
  ' "$scratch/consent" >/dev/null || return 1
  jq --slurpfile flow "$scratch/flow-id.json" '.data |
    {flow_id:$flow[0],client_id,consent:true,pre_configure:false,claims:(.claims // [])}' \
    "$scratch/consent" > "$scratch/consent-body" || return 1
  fetch --header "Origin: $issuer" --referer "$issuer/" --header 'Content-Type: application/json' \
    --data-binary "@$scratch/consent-body" "$issuer/api/oidc/consent" > "$scratch/consent-response" || return 1
  jq -e --arg issuer "$issuer" '.status == "OK" and
    (.data.redirect_uri | startswith($issuer + "/api/oidc/authorization?"))' "$scratch/consent-response" >/dev/null || return 1
  jq -r '"url = " + (.data.redirect_uri | tojson)' "$scratch/consent-response" > "$scratch/consent-redirect" || return 1
  fetch --location --config "$scratch/consent-redirect" --output "$scratch/application" \
    --write-out '%{url_effective}' > "$scratch/final-url" || return 1
  jq -eR --arg app "$app" 'startswith($app + "/")' "$scratch/final-url" >/dev/null
}
initial_state() {
  sed -n "s/.*id=\"initial-state-core-$1\" value=\"\([^\"]*\)\".*/\1/p" "$2" \
    | jq --raw-input '@base64d | fromjson'
}
fetch "$issuer/.well-known/openid-configuration" > "$scratch/discovery"
jq -e --arg issuer "$issuer" '.issuer == $issuer' "$scratch/discovery" >/dev/null
phase='first-factor authentication'
jq -e --arg target "$app/" '{username, password, keepMeLoggedIn: false, targetURL: $target} |
  select((.username | type == "string") and (.password | type == "string"))' "$credentials" > "$scratch/login"
fetch --header "Origin: $issuer" --referer "$issuer/" --header 'Content-Type: application/json' \
  --data-binary "@$scratch/login" "$issuer/api/firstfactor" > "$scratch/login-response"
jq -e '.status == "OK"' "$scratch/login-response" >/dev/null
case "$kind" in
  forgejo)
    phase='Forgejo OIDC login and identity'
    authorize "$app/user/oauth2/Ryra"
    phase='Forgejo signed-in profile and administration denial'
    fetch "$app/user/settings" > "$scratch/profile"
    profile_user=$(sed -n 's/.*<input name="name" value="\([^"]*\)".*/\1/p' "$scratch/profile")
    [[ "$profile_user" == "$expected_user" ]] || { echo 'Forgejo profile identity did not match.' >&2; exit 1; }
    status=$(fetch --no-fail-with-body --output /dev/null --write-out '%{http_code}' "$app/admin")
    [[ "$status" == 403 ]] || { echo 'Shared Forgejo user was not refused site administration.' >&2; exit 1; }
    phase='Forgejo anonymous access denial'
    status=$(client_fetch --no-fail-with-body --output /dev/null --write-out '%{http_code}' "$app/api/v1/user")
    [[ "$status" == 403 ]] || { echo 'Anonymous Forgejo user API did not return 403.' >&2; exit 1; }
    ;;
  grafana)
    phase='Grafana OIDC login'
    authorize "$app/login/generic_oauth"
    if [[ $(cat "$scratch/final-url") == *'/login?'* ]]; then
      echo 'Grafana returned to its login page after OAuth.' >&2
      exit 1
    fi
    phase='Grafana identity and Viewer verification'
    fetch "$app/api/user" > "$scratch/profile"
    jq -e --arg user "$expected_user" '.login == $user and .isGrafanaAdmin == false' "$scratch/profile" >/dev/null
    fetch "$app/api/user/orgs" > "$scratch/orgs"
    jq -e 'length > 0 and all(.[]; .role == "Viewer")' "$scratch/orgs" >/dev/null
    phase='Grafana anonymous access denial'
    status=$(client_fetch --output /dev/null --write-out '%{http_code}' "$app/api/user" || true)
    [[ "$status" == 401 ]] || { echo 'Anonymous Grafana user API did not return 401.' >&2; exit 1; }
    ;;
  nextcloud)
    phase='Nextcloud login page'
    fetch --location "$app/login" > "$scratch/login-page"
    initial_logins=$(sed -n 's/.*id="initial-state-core-alternativeLogins" value="\([^"]*\)".*/\1/p' "$scratch/login-page")
    login_path=$(printf '%s' "$initial_logins" | jq --raw-input --raw-output '
      @base64d | fromjson | map(.href | select(test("^/(index.php/)?apps/user_oidc/login/[0-9]+$"))) | first // empty')
    [[ -n "$login_path" ]] || { echo 'Nextcloud login page has no native OIDC login link.' >&2; exit 1; }
    phase='Nextcloud OAuth authorization and callback'
    if ! authorize "$app$login_path"; then
      printf 'Nextcloud OAuth final endpoint: ' >&2
      sed -E 's/[?#].*$//' "$scratch/final-url" >&2
      exit 1
    fi
    phase='Nextcloud identity verification'
    fetch --header 'OCS-APIRequest: true' "$app/ocs/v2.php/cloud/user?format=json" > "$scratch/profile"
    jq -e --arg user "$expected_user" '.ocs.meta.statuscode == 200 and .ocs.data.id == $user' "$scratch/profile" >/dev/null
    status=$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
      --proto '=https' --connect-timeout 10 --max-time 30 "$app/remote.php/dav/")
    [[ "$status" == 401 ]] || { echo 'Anonymous DAV did not return 401.' >&2; exit 1; }

    phase='login-v2 initiation'
    client_fetch --request POST --header 'User-Agent: Ryra auth smoke' "$app/login/v2" > "$scratch/flow"
    jq -e --arg app "$app" '.login | startswith($app + "/")' "$scratch/flow" >/dev/null
    jq -r '"url = " + (.login | tojson)' "$scratch/flow" > "$scratch/flow-url"
    phase='login-v2 browser landing'
    fetch --location --config "$scratch/flow-url" > "$scratch/flow-page"
    initial_state loginFlowAuth "$scratch/flow-page" > "$scratch/flow-auth"
    jq -e --arg app "$app" '.loginRedirectUrl | startswith($app + "/")' "$scratch/flow-auth" >/dev/null
    jq -r '"url = " + (.loginRedirectUrl | tojson)' "$scratch/flow-auth" > "$scratch/grant-url"
    phase='login-v2 grant page'
    fetch --location --config "$scratch/grant-url" > "$scratch/grant-page"
    initial_state loginFlowGrant "$scratch/grant-page" > "$scratch/grant"
    jq -e --arg app "$app" --arg user "$expected_user" \
      '.userId == $user and (.actionUrl | startswith($app + "/"))' "$scratch/grant" >/dev/null
    jq -r '"url = " + (.actionUrl | tojson)' "$scratch/grant" > "$scratch/grant-url"
    jq -j '"stateToken=" + (.stateToken | @uri)' "$scratch/grant" > "$scratch/grant-body"
    sed -n 's/.*data-requesttoken="\([^"]*\)".*/requesttoken: \1/p' "$scratch/grant-page" > "$scratch/csrf-header"
    [[ -s "$scratch/csrf-header" ]] || { echo 'Login-v2 grant page has no CSRF token.' >&2; exit 1; }
    phase='login-v2 browser approval'
    fetch --header "@$scratch/csrf-header" --header "Origin: $app" \
      --data-binary "@$scratch/grant-body" --config "$scratch/grant-url" > "$scratch/approved"
    jq -e --arg app "$app" '.poll.endpoint | startswith($app + "/")' "$scratch/flow" >/dev/null
    jq -r '"url = " + (.poll.endpoint | tojson)' "$scratch/flow" > "$scratch/poll-url"
    jq -j '"token=" + (.poll.token | @uri)' "$scratch/flow" > "$scratch/poll-body"
    phase='login-v2 credential poll'
    client_fetch --data-binary "@$scratch/poll-body" --config "$scratch/poll-url" > "$scratch/app-password"
    jq -e --arg app "$app" --arg user "$expected_user" \
      '.server == $app and .loginName == $user and (.appPassword | type == "string" and length > 0)' "$scratch/app-password" >/dev/null
    jq -r '"Authorization: Basic " + ((.loginName + ":" + .appPassword) | @base64)' "$scratch/app-password" > "$scratch/dav-auth"
    user_path=$(printf '%s' "$expected_user" | jq --raw-input --raw-output '@uri')
    for collection in "files/$user_path" "calendars/$user_path" "addressbooks/users/$user_path"; do
      phase="DAV collection $collection"
      status=$(curl --silent --show-error --fail --proto '=https' --connect-timeout 10 --max-time 60 \
        --header "@$scratch/dav-auth" --header 'Depth: 0' --request PROPFIND \
        --output "$scratch/dav-response" --write-out '%{http_code}' "$app/remote.php/dav/$collection/")
      [[ "$status" == 207 ]] || { echo 'Authenticated DAV collection did not return 207.' >&2; exit 1; }
    done
    phase='DAV write/read/delete'
    canary="ryra-auth-smoke-$(basename "$scratch").txt"
    printf 'url = "%s/remote.php/dav/files/%s/%s"\n' "$app" "$user_path" "$canary" > "$scratch/canary-url"
    printf 'Ryra native login-v2 DAV smoke\n' > "$scratch/canary"
    curl --silent --show-error --fail --proto '=https' --connect-timeout 10 --max-time 60 \
      --header "@$scratch/dav-auth" --header 'If-None-Match: *' --config "$scratch/canary-url" \
      --upload-file "$scratch/canary" --output /dev/null
    curl --silent --show-error --fail --proto '=https' --connect-timeout 10 --max-time 60 \
      --header "@$scratch/dav-auth" --config "$scratch/canary-url" --output "$scratch/canary-read"
    cmp "$scratch/canary" "$scratch/canary-read"
    curl --silent --show-error --fail --proto '=https' --connect-timeout 10 --max-time 60 \
      --header "@$scratch/dav-auth" --config "$scratch/canary-url" --request DELETE --output /dev/null
    rm "$scratch/canary-url"
    curl --silent --show-error --fail --proto '=https' --connect-timeout 10 --max-time 60 \
      --header "@$scratch/dav-auth" --header 'OCS-APIRequest: true' --request DELETE \
      "$app/ocs/v2.php/core/apppassword" --output /dev/null
    rm "$scratch/dav-auth"
    ;;
  linkding)
    phase='Linkding OIDC login and profile'
    authorize "$app/oidc/authenticate/"
    fetch "$app/api/user/profile/" > "$scratch/profile"
    jq -e '(.version | type) == "string" and (.theme | type) == "string"' "$scratch/profile" >/dev/null
    phase='Linkding native API token creation'
    fetch "$app/settings/integrations" > "$scratch/integrations"
    awk '$6 == "ld_csrftoken" { print "X-CSRFToken: " $7 }' "$jar" > "$scratch/linkding-csrf"
    [[ -s "$scratch/linkding-csrf" ]] || { echo 'Linkding CSRF cookie is missing.' >&2; exit 1; }
    token_name="Ryra auth smoke $(basename "$scratch")"
    printf '%s' "$token_name" | jq -Rj '"name=" + @uri' > "$scratch/create-token-body"
    fetch --location --header "@$scratch/linkding-csrf" --referer "$app/settings/integrations" \
      --data-binary "@$scratch/create-token-body" "$app/settings/integrations/create-api-token" > "$scratch/integrations"
    awk 'BEGIN { RS=">" } /id="new-token-key"/ {
      if (match($0, /value="[^"]+"/)) { key=substr($0,RSTART+7,RLENGTH-8); print "Authorization: Token " key }
    }' "$scratch/integrations" > "$scratch/linkding-auth"
    [[ -s "$scratch/linkding-auth" ]] || { echo 'Linkding did not return its new API token.' >&2; exit 1; }
    token_id=$(awk -v name="$token_name" 'BEGIN { RS="</tr>" } index($0,name) {
      if (match($0, /name="token_id"[[:space:]]+value="[0-9]+"/)) {
        field=substr($0,RSTART,RLENGTH); sub(/.*value="/,"",field); sub(/"$/,"",field); print field
      }
    }' "$scratch/integrations")
    [[ "$token_id" =~ ^[0-9]+$ ]] || { echo 'Linkding smoke token id is missing.' >&2; exit 1; }
    printf 'token_id=%s' "$token_id" > "$scratch/delete-token-body"
    phase='Linkding token API canary'
    client_fetch --header "@$scratch/linkding-auth" "$app/api/user/profile/" > "$scratch/token-profile"
    jq -e '(.version | type) == "string"' "$scratch/token-profile" >/dev/null
    canary_url="https://ryra-smoke.invalid/$(basename "$scratch")"
    jq -n --arg url "$canary_url" '{url:$url,title:"Ryra auth smoke"}' > "$scratch/bookmark-body"
    status=$(client_fetch --header "@$scratch/linkding-auth" --header 'Content-Type: application/json' \
      --data-binary "@$scratch/bookmark-body" --output "$scratch/bookmark" --write-out '%{http_code}' "$app/api/bookmarks/")
    [[ "$status" == 201 ]] || { echo 'Linkding bookmark create did not return 201.' >&2; exit 1; }
    jq -er '.id | select(type == "number")' "$scratch/bookmark" > "$scratch/bookmark-id"
    bookmark_id=$(cat "$scratch/bookmark-id")
    client_fetch --header "@$scratch/linkding-auth" "$app/api/bookmarks/$bookmark_id/" > "$scratch/bookmark-read"
    jq -e --arg url "$canary_url" '.url == $url and .title == "Ryra auth smoke"' "$scratch/bookmark-read" >/dev/null
    status=$(client_fetch --header "@$scratch/linkding-auth" --request DELETE --output /dev/null \
      --write-out '%{http_code}' "$app/api/bookmarks/$bookmark_id/")
    [[ "$status" == 204 ]] || { echo 'Linkding bookmark delete did not return 204.' >&2; exit 1; }
    rm "$scratch/bookmark-id"
    status=$(curl --silent --show-error --proto '=https' --connect-timeout 10 --max-time 30 \
      --header "@$scratch/linkding-auth" --output /dev/null --write-out '%{http_code}' "$app/api/bookmarks/$bookmark_id/")
    [[ "$status" == 404 ]] || { echo 'Deleted Linkding bookmark did not return 404.' >&2; exit 1; }
    fetch --header "@$scratch/linkding-csrf" --referer "$app/settings/integrations" \
      --data-binary "@$scratch/delete-token-body" "$app/settings/integrations/delete-api-token" --output /dev/null
    rm "$scratch/delete-token-body"
    status=$(curl --silent --show-error --proto '=https' --connect-timeout 10 --max-time 30 \
      --header "@$scratch/linkding-auth" --output /dev/null --write-out '%{http_code}' "$app/api/user/profile/")
    [[ "$status" == 401 ]] || { echo 'Revoked Linkding token did not return 401.' >&2; exit 1; }
    ;;
esac
if [[ "$kind" == forgejo ]]; then
  echo 'Forgejo OIDC identity, ordinary account and anonymous API denial passed.'
elif [[ "$kind" == grafana ]]; then
  echo 'Grafana OIDC identity, Viewer role, no server administration and anonymous API denial passed.'
elif [[ "$kind" == nextcloud ]]; then
  echo 'Nextcloud OIDC identity, native login-v2 approval, WebDAV/CalDAV/CardDAV 207 and DAV write/read/delete passed; smoke app password revoked.'
else
  echo 'Linkding OIDC session and native token API create/read/delete passed; revoked token returned 401. Confirm identity mapping in the service database.'
fi
