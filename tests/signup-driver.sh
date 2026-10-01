#!/usr/bin/env bash
set -Eeuo pipefail
FIXTURE="$1"
ACTION="$2"
EVENTS="$3"
source "$FIXTURE/scripts/$ACTION-signups.sh"

vw_compose() { printf '%s\n' "$*" >>"$EVENTS"; }
vw_wait_for_alive() { return 0; }
vw_api_registration_closed() { [[ "$(vw_env_read SIGNUPS_ALLOWED)" == false ]]; }
vw_api_registration_open() { [[ "$(vw_env_read SIGNUPS_ALLOWED)" == true ]]; }
read() {
  local target="${@: -1}"
  printf -v "$target" '%s' "${ANSWER-OPEN}"
}

main
