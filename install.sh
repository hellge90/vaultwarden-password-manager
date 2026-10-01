#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/scripts/common.sh"

main() {
  if [[ "$(id -u)" -eq 0 ]]; then
    vw_die "Run this installer as your regular Linux user, not with sudo: bash install.sh"
  fi
  if [[ -e "$VW_ROOT/.env" || -e "$VW_ROOT/vw-data" ]]; then
    printf 'An install or existing data directory is already present. Nothing was changed.\n'
    bash "$VW_ROOT/scripts/status.sh"
    printf '\nReview docs/troubleshooting.md for recovery. Do not delete or overwrite the existing data.\n'
    return 0
  fi
  if [[ -e "$VW_ROOT/compose.yaml" ]] && [[ -n "$(vw_docker ps --filter "label=com.docker.compose.project=$(vw_project_name)" -q 2>/dev/null || true)" ]]; then
    vw_die "A Compose container already uses this project identity. Nothing was changed."
  fi

  vw_check_linux_prerequisites
  vw_check_loopback_port 8080
  vw_check_tailscale_login
  vw_check_serve_and_funnel_clear

  local dns_name domain image
  dns_name="$(vw_tailscale_dns_name)"
  [[ -n "$dns_name" ]] || vw_die "Tailscale did not provide a DNSName for this device. Check MagicDNS and tailscale status --json."
  [[ "$dns_name" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.ts\.net$ && "$dns_name" != *..* ]] || vw_die "Tailscale returned an unexpected DNSName; refusing to use it in .env or an HTTPS URL."
  domain="https://${dns_name}"
  image="vaultwarden/server:1.37.3"

  printf '\nBefore enabling HTTPS, Tailscale will publish this device name and tailnet DNS name in the public Certificate Transparency log:\n  %s\nThis makes certificate issuance auditable, not the vault publicly reachable. Rename any sensitive machine name first.\n' "$dns_name"
  read -r -p "Have you reviewed this and do you want to continue? Type YES: " answer
  [[ "$answer" == "YES" ]] || vw_die "HTTPS setup was not approved; no files, container, or Serve route were created."

  install -d -m 700 "$VW_ROOT/vw-data"
  cat >"$VW_ROOT/.env" <<EOF
VAULTWARDEN_IMAGE=$image
VAULTWARDEN_DOMAIN=$domain
SIGNUPS_ALLOWED=false
EOF
  chmod 600 "$VW_ROOT/.env"
  vw_compose config --quiet || vw_die "Compose configuration is invalid. Review .env and compose.yaml; the service has not been started."

  printf 'Pulling the pinned image and starting with registration closed...\n'
  vw_compose pull vaultwarden
  vw_compose up -d --no-deps vaultwarden
  vw_wait_for_alive || {
    printf '\nThe service did not pass its local health check. Diagnostics:\n' >&2
    vw_compose ps >&2 || true
    vw_compose logs --tail 80 vaultwarden >&2 || true
    vw_compose stop vaultwarden || true
    vw_die "Setup did not pass health checks. No Tailscale Serve route was configured."
  }

  if ! vw_confirm_serve_and_funnel_clear; then
    vw_compose stop vaultwarden || true
    vw_die "Tailscale Serve/Funnel changed while setup was running. The Vaultwarden service was stopped; inspect Tailscale status and rerun only after resolving the conflict."
  fi
  if ! sudo tailscale serve --bg "http://127.0.0.1:8080"; then
    vw_compose stop vaultwarden || true
    vw_die "Tailscale Serve could not be configured. The Vaultwarden service was stopped. Inspect Tailscale status; no reset was attempted."
  fi

  printf '\nTailscale Serve status:\n'
  sudo tailscale serve status
  if ! vw_wait_for_https "$domain"; then
    printf '\nThe local HTTPS check did not validate the certificate. Tailscale may need HTTPS approval or DNS propagation.\n' >&2
    printf 'Do not bypass TLS checks. Review docs/troubleshooting.md and the Tailscale approval link, if one was shown.\n' >&2
    vw_compose stop vaultwarden || true
    vw_die "HTTPS was not validated; setup is incomplete."
  fi

  printf '\nLocal HTTPS certificate check passed for %s\n' "$domain"
  printf 'This Pi-local result does not prove a remote client can connect. Check from another Tailscale-connected device.\n\n'
  printf 'Next steps:\n'
  printf '1. On another device connected to Tailscale, open %s\n' "$domain"
  printf '2. Deliberately open registration with: bash scripts/open-signups.sh\n'
  printf '3. Create your first vault account (not an admin account); never share your master password.\n'
  printf '4. Immediately close registration with: bash scripts/close-signups.sh\n'
  printf '5. Confirm it reports registration closed, then sign in and test the account.\n'
  printf '6. Install the official Bitwarden clients, configure this exact self-hosted HTTPS URL, and test manual sync.\n'
  printf '7. Enable 2FA, store the recovery code offline, and follow docs/backup-and-restore.md.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
