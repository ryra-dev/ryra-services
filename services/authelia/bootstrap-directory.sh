#!/usr/bin/env bash
set -euo pipefail
umask 077
: "${INITIAL_USERNAME:?Choose the initial username}"
: "${INITIAL_EMAIL:?Choose the initial email}"
: "${INITIAL_PASSWORD:?Choose the initial password}"
if [[ ! "$INITIAL_USERNAME" =~ ^[a-z][a-z0-9._-]*$ || "$INITIAL_USERNAME" == directory-admin || "$INITIAL_USERNAME" == authelia || ${#INITIAL_PASSWORD} -lt 8 || "$INITIAL_EMAIL" != *@* ]]; then
  echo 'Initial authentication account requires a distinct lowercase username, email and password of at least eight characters.' >&2
  exit 1
fi
credentials=${CREDENTIALS_DIRECTORY:?}
runtime=${RUNTIME_DIRECTORY:?}
base=${LLDAP_URL:?}
token=
post() {
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl --config - --fail --silent --show-error --max-time 30 \
      --header 'Content-Type: application/json' --data-binary @"$runtime/request.json" "$base/$1"
}
jq -n --rawfile password "$credentials/admin" '{username:"directory-admin", password:($password|rtrimstr("\n"))}' > "$runtime/request.json"
for _ in {1..90}; do
  if response=$(post auth/simple/login 2>/dev/null) && token=$(printf '%s' "$response" | jq -er '.token | select(type == "string" and length > 0)'); then
    break
  fi
  sleep 2
done
if [[ -z "$token" ]]; then
  echo 'LLDAP administrator login failed; check the directory service and credentials.' >&2
  exit 1
fi
graphql() {
  local query=$1 variables=${2:-'{}'} response
  printf '%s' "$variables" | jq --arg query "$query" '{query:$query, variables:.}' > "$runtime/request.json"
  response=$(post api/graphql)
  if ! printf '%s' "$response" | jq -e '(.errors // [] | length) == 0 and .data != null' >/dev/null; then
    echo 'Managed directory setup failed; the directory rejected an operation.' >&2
    exit 1
  fi
  printf '%s' "$response" | jq '.data'
}
users=$(graphql '{ users { id } }')
ensure_user() {
  local username=$1 email=$2
  if ! printf '%s' "$users" | jq -e --arg user "$username" '.users | any(.id == $user)' >/dev/null; then
    printf '%s' "$username" > "$runtime/username"
    printf '%s' "$email" > "$runtime/email"
    variables=$(jq -n --rawfile id "$runtime/username" --rawfile email "$runtime/email" '{user:{id:$id,email:$email,displayName:$id}}')
    graphql 'mutation($user: CreateUserInput!) { createUser(user:$user) { id } }' "$variables" >/dev/null
  fi
}
ensure_user authelia 'authelia@localhost.invalid'
ensure_user "$INITIAL_USERNAME" "$INITIAL_EMAIL"
# GraphQL does not expose whether OPAQUE password registration completed.
registered=$(sqlite3 -readonly "${LLDAP_DATABASE:?}" "SELECT password_hash IS NOT NULL FROM users WHERE user_id = '$INITIAL_USERNAME';")
case "$registered" in
  0)
    printf '%s' "$INITIAL_PASSWORD" > "$runtime/initial-password"
    if ! ldappasswd -x -H "${LLDAP_ADDRESS:?}" -D "uid=directory-admin,ou=people,${LLDAP_BASE_DN:?}" \
      -y "$credentials/admin" -T "$runtime/initial-password" "uid=$INITIAL_USERNAME,ou=people,$LLDAP_BASE_DN" >/dev/null 2>&1; then
      echo 'Could not finish initial account password registration.' >&2
      exit 1
    fi
    rm "$runtime/initial-password"
    ;;
  1) ;;
  *) echo 'Initial directory account is missing from persistent storage.' >&2; exit 1 ;;
esac
unset INITIAL_PASSWORD
if ! ldappasswd -x -H "$LLDAP_ADDRESS" -D "uid=directory-admin,ou=people,$LLDAP_BASE_DN" \
  -y "$credentials/admin" -T "$credentials/bind" "uid=authelia,ou=people,$LLDAP_BASE_DN" >/dev/null 2>&1; then
  echo 'Could not configure the managed directory reader password.' >&2
  exit 1
fi
groups=$(graphql '{ groups { id displayName } }')
for group in service_users service_admins; do
  if ! printf '%s' "$groups" | jq -e --arg group "$group" '.groups | any(.displayName == $group)' >/dev/null; then
    graphql 'mutation($name:String!) { createGroup(name:$name) { id } }' "$(jq -n --arg name "$group" '{name:$name}')" >/dev/null
  fi
done
groups=$(graphql '{ groups { id displayName } }')
membership() {
  local username=$1 group=$2 present=$3 group_id current operation
  group_id=$(printf '%s' "$groups" | jq -er --arg name "$group" '.groups[] | select(.displayName == $name) | .id')
  current=$(graphql 'query($id:String!) { user(userId:$id) { groups { id } } }' "$(jq -n --arg id "$username" '{id:$id}')")
  if printf '%s' "$current" | jq -e --argjson id "$group_id" '.user.groups | any(.id == $id)' >/dev/null; then
    [[ "$present" == false ]] || return 0
    operation=removeUserFromGroup
  else
    [[ "$present" == true ]] || return 0
    operation=addUserToGroup
  fi
  graphql "mutation(\$user:String!,\$group:Int!) { $operation(userId:\$user,groupId:\$group) { ok } }" \
    "$(jq -n --arg user "$username" --argjson group "$group_id" '{user:$user,group:$group}')" >/dev/null
}
membership "$INITIAL_USERNAME" service_users true
membership "$INITIAL_USERNAME" service_admins true
membership "$INITIAL_USERNAME" lldap_admin true
membership authelia lldap_strict_readonly true
for username in directory-admin authelia; do
  membership "$username" service_users false
  membership "$username" service_admins false
done
rm -f "$runtime/request.json" "$runtime/username" "$runtime/email"
echo 'Managed directory is ready; established human passwords preserved.'
