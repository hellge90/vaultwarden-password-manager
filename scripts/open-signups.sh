#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/common.sh"

main() {
  [[ -f "$VW_ENV_FILE" ]] || vw_die "No .env exists. Run bash install.sh first."
  vw_check_signup_override
  printf 'Opening registration lets any other authorized Tailscale user who can reach this service create an account.\n'
  read -r -p "Type OPEN to continue: " answer
  [[ "$answer" == OPEN ]] || vw_die "Registration was not opened."
  vw_env_set_known SIGNUPS_ALLOWED true
  vw_compose config --quiet
  vw_compose up -d --no-deps --force-recreate vaultwarden
  vw_wait_for_alive || vw_die "Vaultwarden did not pass the local health check after reopening registration. Check 'sudo docker compose logs vaultwarden'."
  vw_api_registration_open || vw_die "Vaultwarden is responding, but its effective registration setting is not verified open. Review config.json and the admin settings."
  printf 'Registration is open. Create the first account now, then immediately run: bash scripts/close-signups.sh\n'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
