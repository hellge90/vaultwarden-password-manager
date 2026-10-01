#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/common.sh"

main() {
  [[ -f "$VW_ENV_FILE" ]] || vw_die "No .env exists. Run bash install.sh first."
  vw_check_signup_override
  current="$(vw_env_read SIGNUPS_ALLOWED)"
  if [[ "$current" == false ]]; then
    if vw_api_registration_closed 2>/dev/null; then
      printf 'Registration is already closed (verified by Vaultwarden).\n'
      return 0
    fi
  fi
  vw_env_set_known SIGNUPS_ALLOWED false
  vw_compose config --quiet
  vw_compose up -d --no-deps --force-recreate vaultwarden
  vw_wait_for_alive || vw_die "Vaultwarden did not pass its local health check after closing registration. Check 'sudo docker compose logs vaultwarden'."
  vw_api_registration_closed || vw_die "Vaultwarden is responding, but its effective registration setting is not verified closed. Stop registration manually and inspect config.json."
  printf 'Registration is closed (verified from Vaultwarden /api/config).\n'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
