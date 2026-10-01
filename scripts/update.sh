#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/backup.sh"

main() {
  vw_require_root update.sh
  [[ $# -eq 1 ]] || vw_die "Choose one verified stable release tag, for example: sudo bash scripts/update.sh 1.37.3"
  local tag="$1" image manifest
  [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || vw_die "Use a plain stable numeric version such as 1.37.3; latest, testing, and prerelease tags are not accepted."
  [[ -f "$VW_ENV_FILE" && -d "$VW_DATA_DIR" ]] || vw_die "No existing install/data directory was found."
  vw_check_signup_override
  vw_lock
  image="vaultwarden/server:$tag"
  manifest="$(vw_docker manifest inspect "$image")" || vw_die "Could not verify the official image manifest for $image."
  python3 -c '
import json, sys
try: data = json.load(sys.stdin)
except json.JSONDecodeError: raise SystemExit("ERROR: image manifest was not valid JSON")
platforms = [entry.get("platform", {}) for entry in data.get("manifests", [])]
if not any(p.get("os") == "linux" and p.get("architecture") == "arm64" for p in platforms):
    raise SystemExit("ERROR: selected stable tag has no linux/arm64 image")
' <<<"$manifest" || vw_die "Selected tag is not verified for Linux ARM64."

  local configured
  configured="$(vw_env_read VAULTWARDEN_IMAGE)"
  [[ "$configured" == vaultwarden/server:* ]] || vw_die "The configured image is not the official vaultwarden/server image; refusing to replace it."
  printf 'Creating and verifying a full pre-update backup before changing the image...\n'
  backup_run "" true
  vw_env_set_known VAULTWARDEN_IMAGE "$image"
  vw_compose config --quiet
  vw_compose pull vaultwarden
  vw_compose up -d --no-deps --force-recreate vaultwarden
  if ! vw_wait_for_alive; then
    printf 'Update health check failed. The old data and verified pre-update archive are preserved; automatic rollback is not attempted because database migrations may be irreversible.\n' >&2
    vw_compose logs --tail 100 vaultwarden >&2 || true
    vw_die "Update did not pass its health check. Follow coordinated restore guidance in docs/backup-and-restore.md."
  fi
  printf 'Vaultwarden is responding after update to %s.\n' "$image"
  printf 'Keep the verified pre-update archive until you have checked login, attachments, and the client. Database migrations can prevent simply switching back to the old image.\n'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
