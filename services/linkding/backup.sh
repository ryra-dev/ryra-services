#!/usr/bin/env bash
set -euo pipefail
umask 077
data=${LINKDING_DATA:?}
snapshot="$data/.ryra-backup/current"
stop_writers() {
  units=(linkding.service linkding-setup.service)
  if [[ -n ${LINKDING_TASKS_UNIT:-} ]]; then units+=("$LINKDING_TASKS_UNIT"); fi
  systemctl stop "${units[@]}"
}
start_writers() {
  units=(linkding.service)
  if [[ -n ${LINKDING_TASKS_UNIT:-} ]]; then units+=("$LINKDING_TASKS_UNIT"); fi
  systemctl start "${units[@]}"
  for _ in {1..30}; do
    if curl --fail --silent --max-time 5 "http://127.0.0.1:${LINKDING_PORT:?}/health" >/dev/null; then return 0; fi
    sleep 1
  done
  echo 'Linkding did not become healthy after its writers restarted.' >&2
  return 1
}
validate() {
  [[ $(sqlite3 -readonly "$1" 'PRAGMA integrity_check;') == ok ]]
}
validate_main() {
  validate "$1"
  [[ $(sqlite3 -readonly "$1" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('auth_user','bookmarks_bookmark');") == 2 ]]
}
case "${1:-}" in
  prepare)
    scratch=
    trap 'if [[ -n "$scratch" ]]; then rm -rf "$scratch"; fi; start_writers' EXIT
    stop_writers
    mkdir -p "$data/.ryra-backup"
    scratch=$(mktemp -d "$data/.ryra-backup/.new.XXXXXX")
    sqlite3 "$data/db.sqlite3" ".backup '$scratch/main.sqlite'"
    validate_main "$scratch/main.sqlite"
    if [[ -f "$data/tasks.sqlite3" ]]; then
      sqlite3 "$data/tasks.sqlite3" ".backup '$scratch/tasks.sqlite'"
      validate "$scratch/tasks.sqlite"
    fi
    rm -rf "$snapshot"
    mv "$scratch" "$snapshot"
    trap - EXIT
    ;;
  finish) start_writers ;;
  before-restore)
    stop_writers
    rm -rf "$snapshot"
    ;;
  after-restore)
    validate_main "$snapshot/main.sqlite"
    if [[ -f "$snapshot/tasks.sqlite" ]]; then validate "$snapshot/tasks.sqlite"; fi
    for database in db.sqlite3 tasks.sqlite3; do
      rm -f "$data/$database-wal" "$data/$database-shm" "$data/$database-journal"
    done
    install -o "${LINKDING_USER:?}" -g "${LINKDING_GROUP:?}" -m 0600 "$snapshot/main.sqlite" "$data/db.sqlite3.restore"
    mv "$data/db.sqlite3.restore" "$data/db.sqlite3"
    if [[ -f "$snapshot/tasks.sqlite" ]]; then
      install -o "$LINKDING_USER" -g "$LINKDING_GROUP" -m 0600 "$snapshot/tasks.sqlite" "$data/tasks.sqlite3.restore"
      mv "$data/tasks.sqlite3.restore" "$data/tasks.sqlite3"
    else
      rm -f "$data/tasks.sqlite3"
    fi
    start_writers
    ;;
  *) echo 'Choose prepare, finish, before-restore or after-restore.' >&2; exit 2 ;;
esac
