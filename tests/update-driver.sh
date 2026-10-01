#!/usr/bin/env bash
set -Eeuo pipefail
source "$1/scripts/update.sh"
EVENTS="$2"
SELECTED_TAG="$3"

vw_require_root() { :; }
vw_lock() { printf 'lock\n' >>"$EVENTS"; }
vw_docker() {
  printf 'docker %s\n' "$*" >>"$EVENTS"
  if [[ "$*" == "manifest inspect vaultwarden/server:$SELECTED_TAG" ]]; then
    if [[ "${NO_ARM64:-0}" == 1 ]]; then
      printf '{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}}]}'
    else
      printf '{"manifests":[{"platform":{"os":"linux","architecture":"arm64"}}]}'
    fi
  fi
}
vw_env_read() { printf '%s\n' "${CONFIGURED_IMAGE:-vaultwarden/server:1.37.3}"; }
vw_env_set_known() { printf 'set %s=%s\n' "$1" "$2" >>"$EVENTS"; }
backup_run() { printf 'backup lock-held=%s\n' "$2" >>"$EVENTS"; }
vw_compose() { printf 'compose %s\n' "$*" >>"$EVENTS"; }
vw_wait_for_alive() { [[ "${HEALTH_FAIL:-0}" != 1 ]]; }

main "$SELECTED_TAG"
