#!/usr/bin/env bash
set -Eeuo pipefail
FIXTURE="$1"
DESTINATION="$2"
STATE="$3"
source "$FIXTURE/scripts/backup.sh"
VW_LOCK_DIR="${LOCK_DIR:-$FIXTURE/lockdir}"
VW_LOCK_FILE="${LOCK_FILE:-$VW_LOCK_DIR/test.lock}"
VW_BACKUP_STATE_FILE="${BACKUP_STATE_FILE:-$FIXTURE/backup-running}"

vw_require_root() { :; }
install() {
  if [[ "${1:-}" == -d ]]; then
    mkdir -p -- "${@: -1}"
  else
    command install "$@"
  fi
}
vw_service_running() { [[ "$(cat "$STATE")" == running ]]; }
vw_compose() {
  printf '%s\n' "$*" >>"$EVENTS"
  case "$1" in
    stop)
      printf 'stopped\n' >"$STATE"
      [[ "${FAIL_STOP:-0}" != 1 ]]
      ;;
    start)
      printf 'running\n' >"$STATE"
      ;;
    *) return 0 ;;
  esac
}
vw_wait_for_alive() { [[ "${HEALTH_FAIL:-0}" != 1 ]]; }
vw_docker() { printf false; }

backup_run "$DESTINATION"
