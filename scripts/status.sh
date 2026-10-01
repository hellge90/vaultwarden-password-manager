#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/common.sh"

printf 'Project folder: %s\n' "$VW_ROOT"
if [[ ! -f "$VW_ENV_FILE" ]]; then
  printf 'Setup: not installed (.env is absent); run bash install.sh on the Pi after prerequisites.\n'
  exit 0
fi
printf 'Compose service status:\n'
vw_compose ps || {
  printf 'Could not read Compose status. Check Docker daemon access; no changes were made.\n' >&2
  exit 1
}
if [[ -f "$VW_CONFIG_FILE" ]]; then
  printf 'Vaultwarden admin config exists; signup helper changes are blocked until its relevant override is reviewed.\n'
fi
if sudo test -e "$VW_BACKUP_STATE_FILE"; then
  printf 'WARNING: a previous backup did not confirm service recovery; inspect Docker health and the marker at %s before another backup.\n' "$VW_BACKUP_STATE_FILE"
fi
if curl --fail --silent --max-time 4 http://127.0.0.1:8080/alive >/dev/null 2>&1; then
  printf 'Local /alive: responding\n'
  if vw_api_registration_closed 2>/dev/null; then
    printf 'Effective registration: closed\n'
  else
    printf 'Effective registration: open or could not be verified; inspect Vaultwarden and config.json.\n'
  fi
else
  printf 'Local /alive: not responding\n'
fi
if command -v tailscale >/dev/null 2>&1; then
  printf 'Tailscale Serve (read-only):\n'
  sudo tailscale serve status || true
  printf 'Tailscale Funnel (read-only):\n'
  sudo tailscale funnel status || true
fi
printf 'This is a Pi-local status check; test HTTPS from a separate Tailscale-connected client too.\n'
