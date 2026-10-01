#!/usr/bin/env bash
# Managed-by: vaultwarden-project-setup
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/common.sh"

backup_cleanup() {
  local original_status=$?
  trap - EXIT
  if [[ -n "${VW_BACKUP_TEMP:-}" && -e "$VW_BACKUP_TEMP" ]]; then
    rm -f -- "$VW_BACKUP_TEMP"
  fi
  if [[ -n "${VW_BACKUP_STAGING:-}" && -d "$VW_BACKUP_STAGING" ]]; then
    rm -f -- "$VW_BACKUP_STAGING/backup-metadata.json"
    rmdir -- "$VW_BACKUP_STAGING" 2>/dev/null || true
  fi
  if [[ "${VW_BACKUP_WAS_RUNNING:-0}" == 1 && "${VW_BACKUP_STOPPED:-0}" == 1 ]]; then
    printf 'Restarting the service because it was running before backup...\n' >&2
    if ! vw_compose start vaultwarden; then
      printf 'ERROR: backup did not restart the previously running service. Inspect Docker and run scripts/status.sh.\n' >&2
      original_status=1
    elif ! vw_wait_for_alive; then
      printf 'ERROR: backup restarted the service, but /alive is not healthy. Inspect Docker logs and scripts/status.sh.\n' >&2
      original_status=1
    else
      if ! rm -f -- "$VW_BACKUP_STATE_FILE"; then
        printf 'ERROR: service is healthy, but the interrupted-backup marker could not be cleared: %s\n' "$VW_BACKUP_STATE_FILE" >&2
        original_status=1
      fi
    fi
  fi
  exit "$original_status"
}

backup_run() {
  local destination="${1:-}"
  local lock_held="${2:-false}"
  if [[ -z "$destination" ]]; then
    local -a config=()
    if config_text="$(vw_root_timer_config 2>/dev/null)"; then
      mapfile -t config <<<"$config_text"
      if [[ "${config[0]:-}" == "$VW_ROOT" ]]; then
        destination="${config[1]:-}"
      fi
    fi
  fi
  destination="${destination:-$VW_ROOT/backups}"
  [[ -d "$VW_DATA_DIR" ]] || vw_die "Data folder '$VW_DATA_DIR' does not exist; refusing to create an empty backup."
  [[ -f "$VW_ENV_FILE" && -f "$VW_COMPOSE_FILE" ]] || vw_die "Required .env or compose.yaml is missing."
  [[ ! -L "$VW_DATA_DIR" && ! -L "$destination" ]] || vw_die "Refusing symlinked data or backup directory."
  destination="$(python3 - "$destination" "$VW_DATA_DIR" <<'PY'
import os, sys
destination, data = (os.path.realpath(path) for path in sys.argv[1:])
if os.path.commonpath((destination, data)) == data:
    raise SystemExit("ERROR: backup destination must not be inside vw-data/")
print(destination)
PY
)" || vw_die "Backup destination must resolve outside vw-data/."
  mkdir -p -- "$destination"
  chmod 700 "$destination"
  destination="$(cd -- "$destination" && pwd -P)"
  [[ -w "$destination" ]] || vw_die "Backup destination is not writable: $destination"
  local available_kb required_kb
  available_kb="$(df -Pk "$destination" | awk 'NR==2 {print $4}')"
  required_kb="$(du -sk "$VW_DATA_DIR" "$VW_ENV_FILE" "$VW_COMPOSE_FILE" | awk '{total += $1} END {print total + 10240}')"
  [[ "$available_kb" =~ ^[0-9]+$ && "$required_kb" =~ ^[0-9]+$ ]] || vw_die "Could not measure available backup space."
  (( available_kb >= required_kb )) || vw_die "Not enough free space at $destination (need approximately ${required_kb} KiB; have ${available_kb} KiB)."
  command -v tar >/dev/null 2>&1 || vw_die "tar is required."
  command -v gzip >/dev/null 2>&1 || vw_die "gzip is required."
  command -v flock >/dev/null 2>&1 || vw_die "flock is required."
  [[ "$lock_held" == true ]] || vw_lock

  [[ ! -e "$VW_BACKUP_STATE_FILE" && ! -L "$VW_BACKUP_STATE_FILE" ]] || vw_die "A prior backup was interrupted before service recovery. Inspect Docker/service health and the marker at $VW_BACKUP_STATE_FILE before another backup."
  VW_BACKUP_WAS_RUNNING=0
  VW_BACKUP_STOPPED=0
  VW_BACKUP_TEMP=""
  VW_BACKUP_STAGING=""
  VW_BACKUP_STATE_CREATED=0
  trap backup_cleanup EXIT
  if vw_service_running; then
    VW_BACKUP_WAS_RUNNING=1
    VW_BACKUP_STOPPED=1
    state_dir="$(dirname -- "$VW_BACKUP_STATE_FILE")"
    install -d -o root -g root -m 700 "$state_dir"
    state_temp="$(mktemp "$state_dir/.backup-state.XXXXXX")"
    printf 'running\n' >"$state_temp"
    chmod 600 "$state_temp"
    mv -- "$state_temp" "$VW_BACKUP_STATE_FILE"
    VW_BACKUP_STATE_CREATED=1
    vw_compose stop vaultwarden
    if vw_service_running; then
      vw_die "Vaultwarden still appears to be running after stop; refusing to archive an inconsistent database."
    fi
  fi
  # A running instance is stopped so SQLite, including WAL, is archived as one
  # consistent directory. If it was already stopped, leave it stopped.
  local stamp final staging metadata image state_dir state_temp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  final="$destination/vaultwarden-$stamp.tar.gz"
  [[ ! -e "$final" ]] || vw_die "Archive name already exists: $final"
  VW_BACKUP_TEMP="$(mktemp "$destination/.vaultwarden-$stamp.tmp.XXXXXX")"
  VW_BACKUP_STAGING="$(mktemp -d "$destination/.vaultwarden-metadata.XXXXXX")"
  staging="$VW_BACKUP_STAGING"
  chmod 700 "$VW_BACKUP_STAGING"
  image="$(vw_env_read VAULTWARDEN_IMAGE)"
  metadata="$staging/backup-metadata.json"
  python3 - "$metadata" "$stamp" "$VW_ROOT" "$image" <<'PY'
import json, os, sys
path, stamp, project, image = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump({"created_utc": stamp, "project_dir": project, "vaultwarden_image": image}, stream, indent=2)
    stream.write("\n")
os.chmod(path, 0o600)
PY
  chmod 600 "$VW_BACKUP_TEMP"
  tar -czf "$VW_BACKUP_TEMP" -C "$VW_ROOT" vw-data .env compose.yaml -C "$staging" backup-metadata.json
  gzip -t "$VW_BACKUP_TEMP"
  tar -tzf "$VW_BACKUP_TEMP" >/dev/null
  rm -f -- "$staging/backup-metadata.json"
  rmdir -- "$staging"
  VW_BACKUP_STAGING=""
  mv -- "$VW_BACKUP_TEMP" "$final"
  VW_BACKUP_TEMP=""
  chmod 600 "$final"
  printf 'Verified archive created: %s\n' "$final"
  printf 'This archive is not additionally encrypted. It contains vault data, keys, and deployment configuration; protect it and keep a copy away from this storage device.\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  vw_require_root backup.sh
  backup_run "$@"
fi
