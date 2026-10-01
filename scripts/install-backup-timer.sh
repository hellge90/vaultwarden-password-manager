#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/common.sh"

main() {
  vw_require_root install-backup-timer.sh
  command -v systemctl >/dev/null 2>&1 || vw_die "systemd/systemctl is required."
  command -v python3 >/dev/null 2>&1 || vw_die "Python 3 is required."
  [[ -f "$VW_ENV_FILE" && -d "$VW_DATA_DIR" ]] || vw_die "Run install.sh and create the data folder before setting up backups."
  local timezone
  timezone="$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || printf 'unknown')"
  printf 'The optional backup timer runs daily at 03:00 in this Pi timezone: %s\n' "$timezone"
  printf 'It writes protected, unencrypted archives to %s/backups. Keep off-device copies yourself; no retention cleanup is installed.\n' "$VW_ROOT"
  read -r -p "Type ENABLE to install and enable this timer: " answer
  [[ "$answer" == ENABLE ]] || vw_die "No timer was installed."

  local target_dir config_dir service_file timer_file tmp_project path
  target_dir=/usr/local/lib/vaultwarden-project-setup
  config_dir=/etc/vaultwarden-project-setup
  service_file=/etc/systemd/system/vaultwarden-backup.service
  timer_file=/etc/systemd/system/vaultwarden-backup.timer
  for path in "$target_dir/common.sh" "$target_dir/backup.sh" "$service_file" "$timer_file"; do
    if [[ -e "$path" ]] && ! grep -q 'Managed-by: vaultwarden-project-setup' "$path"; then
      vw_die "Refusing to overwrite existing unrelated file: $path"
    fi
  done
  sudo install -d -o root -g root -m 755 "$target_dir" "$config_dir"
  sudo install -o root -g root -m 755 "$VW_ROOT/scripts/common.sh" "$target_dir/common.sh"
  sudo install -o root -g root -m 755 "$VW_ROOT/scripts/backup.sh" "$target_dir/backup.sh"
  tmp_project="$(mktemp)"
  trap 'rm -f -- "$tmp_project"' EXIT
  python3 - "$tmp_project" "$VW_ROOT" "$VW_ROOT/backups" <<'PY'
import json, os, sys
project_file, project, backup = sys.argv[1:]
with open(project_file, "w", encoding="utf-8") as stream:
    json.dump({"project_dir": os.path.realpath(project), "backup_dir": os.path.realpath(backup)}, stream)
PY
  sudo install -o root -g root -m 600 "$tmp_project" "$config_dir/backup.json"
  for path in "$service_file" "$timer_file"; do
    if [[ -e "$path" ]] && ! grep -q 'Managed-by: vaultwarden-project-setup' "$path"; then
      vw_die "Refusing to overwrite existing unrelated systemd unit: $path"
    fi
  done
  sudo tee "$service_file" >/dev/null <<EOF
# Managed-by: vaultwarden-project-setup
[Unit]
Description=Consistent Vaultwarden data backup
After=docker.service tailscaled.service
Requires=docker.service

[Service]
Type=oneshot
Environment=VW_ROOT_CONFIG=$config_dir/backup.json
ExecStart=$target_dir/backup.sh
EOF
  sudo tee "$timer_file" >/dev/null <<'EOF'
# Managed-by: vaultwarden-project-setup
[Unit]
Description=Daily Vaultwarden backup at 03:00 local time

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
Unit=vaultwarden-backup.service

[Install]
WantedBy=timers.target
EOF
  sudo chown root:root "$service_file" "$timer_file"
  sudo chmod 644 "$service_file" "$timer_file"
  sudo systemctl daemon-reload
  sudo systemctl enable --now vaultwarden-backup.timer
  sudo systemctl status vaultwarden-backup.timer --no-pager
  printf '\nTimer installed. It does not prune old backups. See docs/backup-and-restore.md for checking the next run and logs.\n'
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
