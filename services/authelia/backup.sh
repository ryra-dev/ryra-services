#!/usr/bin/env bash
set -euo pipefail
umask 077
state=${AUTH_STATE:?}
stop_auth() {
  systemctl stop "${AUTH_UNIT:?}" ryra-auth-bootstrap.service lldap.service
}
start_auth() {
  systemctl start "$AUTH_UNIT"
  for _ in {1..30}; do
    if curl --fail --silent --max-time 5 "http://127.0.0.1:${AUTH_PORT:?}/api/health" | jq -e '.status == "OK"' >/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo 'Authelia did not become healthy after authentication services restarted.' >&2
  return 1
}
check_database() {
  [[ $(sqlite3 -readonly "$1" 'PRAGMA integrity_check;') == ok ]]
  [[ $(sqlite3 -readonly "$1" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='$2';") == 1 ]]
}
case "${1:-}" in
  prepare)
    start_auth
    scratch=
    trap 'if [[ -n "$scratch" ]]; then rm -rf "$scratch"; fi; start_auth' EXIT
    stop_auth
    mkdir -p "$state/.ryra-backup"
    scratch=$(mktemp -d "$state/.ryra-backup/.new.XXXXXX")
    sqlite3 -readonly "$state/lldap/users.db" ".backup '$scratch/lldap.sqlite'"
    sqlite3 -readonly "$state/authelia/db.sqlite3" ".backup '$scratch/authelia.sqlite'"
    check_database "$scratch/lldap.sqlite" users
    check_database "$scratch/authelia.sqlite" migrations
    cp -a "$state/keys" "$state/clients" "$scratch/"
    rm -rf "$state/.ryra-backup/current"
    mv "$scratch" "$state/.ryra-backup/current"
    trap - EXIT
    ;;
  finish) start_auth ;;
  before-restore)
    stop_auth
    rm -rf "$state/.ryra-backup/current"
    ;;
  after-restore)
    snapshot="$state/.ryra-backup/current"
    check_database "$snapshot/lldap.sqlite" users
    check_database "$snapshot/authelia.sqlite" migrations
    for key in jwt session storage hmac signing ldap-bind ldap-admin ldap-jwt lldap.env; do
      [[ -s "$snapshot/keys/current/$key" ]]
    done
    # The provider restores files while both SQLite writers are stopped.
    cp -a "$snapshot/keys/." "$state/keys/"
    cp -a "$snapshot/clients/." "$state/clients/"
    for database in "$state/lldap/users.db" "$state/authelia/db.sqlite3"; do
      rm -f "$database-wal" "$database-shm" "$database-journal"
    done
    install -o lldap -g lldap -m 0600 "$snapshot/lldap.sqlite" "$state/lldap/users.db.restore"
    install -o "${AUTH_USER:?}" -g "${AUTH_GROUP:?}" -m 0600 "$snapshot/authelia.sqlite" "$state/authelia/db.sqlite3.restore"
    mv "$state/lldap/users.db.restore" "$state/lldap/users.db"
    mv "$state/authelia/db.sqlite3.restore" "$state/authelia/db.sqlite3"
    start_auth
    ;;
  *) echo 'Choose prepare, finish, before-restore or after-restore.' >&2; exit 2 ;;
esac
