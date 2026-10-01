#!/usr/bin/env bash
set -Eeuo pipefail
FIXTURE="$1"
source "$FIXTURE/install.sh"
EVENTS="$2"

id() {
  if [[ "${1:-}" == -u ]]; then
    printf '1000\n'
  else
    command id "$@"
  fi
}
vw_check_linux_prerequisites() { :; }
vw_check_loopback_port() { :; }
vw_check_tailscale_login() { :; }
vw_check_serve_and_funnel_clear() {
  if [[ "${SCENARIO:-}" == serve-conflict || "${SCENARIO:-}" == funnel-conflict ]]; then
    vw_die "mock Tailscale route conflict"
  fi
}
vw_confirm_serve_and_funnel_clear() { [[ "${SCENARIO:-}" != route-race ]]; }
vw_tailscale_dns_name() { printf '%s' "${DNS_NAME-pi.example.ts.net}"; }
vw_wait_for_alive() { [[ "${SCENARIO:-}" != health-fail ]]; }
vw_wait_for_https() { [[ "${SCENARIO:-}" != https-fail ]]; }
sudo() {
  printf 'sudo %s\n' "$*" >>"$EVENTS"
}
read() {
  local target="${@: -1}"
  printf -v "$target" '%s' "${ANSWER:-YES}"
}
install() {
  if [[ "${1:-}" == -d ]]; then
    mkdir -p -- "${@: -1}"
  else
    command install "$@"
  fi
}
bash() {
  printf 'read-only-status %s\n' "$*" >>"$EVENTS"
}
vw_compose() {
  printf '%s\n' "$*" >>"$EVENTS"
  case "$1:${SCENARIO:-}" in
    pull:pull-fail) return 9 ;;
    up:*)
      printf 'running\n' >"$FIXTURE/service-state"
      ;;
    stop:*)
      printf 'stopped\n' >"$FIXTURE/service-state"
      ;;
    *) ;;
  esac
}
main
