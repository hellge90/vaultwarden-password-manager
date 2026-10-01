#!/usr/bin/env bash
# Managed-by: vaultwarden-project-setup

VW_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [[ -n "${VW_ROOT_CONFIG:-}" && -r "$VW_ROOT_CONFIG" ]]; then
  VW_ROOT="$(python3 - "$VW_ROOT_CONFIG" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    config = json.load(stream)
path = config.get("project_dir") if isinstance(config, dict) else None
if not isinstance(path, str) or not os.path.isabs(path):
    raise SystemExit("ERROR: root backup configuration has no absolute project_dir")
print(os.path.realpath(path))
PY
)"
fi
VW_COMPOSE_FILE="$VW_ROOT/compose.yaml"
VW_ENV_FILE="$VW_ROOT/.env"
VW_DATA_DIR="$VW_ROOT/vw-data"
VW_CONFIG_FILE="$VW_DATA_DIR/config.json"
VW_LOCK_DIR="/run/vaultwarden-project-setup"
VW_LOCK_FILE="$VW_LOCK_DIR/$(printf '%s' "$VW_ROOT" | sha256sum | cut -c1-16).lock"
VW_BACKUP_STATE_FILE="/var/lib/vaultwarden-project-setup/$(printf '%s' "$VW_ROOT" | sha256sum | cut -c1-16).backup-running"

vw_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

vw_note() {
  printf '%s\n' "$*"
}

vw_require_command() {
  command -v "$1" >/dev/null 2>&1 || vw_die "Required command '$1' was not found. See docs/prerequisites.md."
}

vw_compose() {
  local -a args=(docker compose --project-directory "$VW_ROOT" --project-name "$(vw_project_name)" --env-file "$VW_ENV_FILE" -f "$VW_COMPOSE_FILE")
  if [[ "$(id -u)" -eq 0 ]]; then
    env -u SIGNUPS_ALLOWED -u VAULTWARDEN_IMAGE -u VAULTWARDEN_DOMAIN "${args[@]}" "$@"
  else
    env -u SIGNUPS_ALLOWED -u VAULTWARDEN_IMAGE -u VAULTWARDEN_DOMAIN sudo "${args[@]}" "$@"
  fi
}

vw_project_name() {
  local digest
  digest="$(printf '%s' "$VW_ROOT" | sha256sum | cut -c1-10)"
  printf 'vaultwarden-%s' "$digest"
}

vw_env_read() {
  local key="$1"
  python3 - "$VW_ENV_FILE" "$key" <<'PY'
import os, re, sys
path, key = sys.argv[1:]
if not os.path.isfile(path) or os.path.islink(path):
    raise SystemExit(f"ERROR: expected a regular, non-symlink env file at {path}")
pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=(.*)$")
values = []
with open(path, encoding="utf-8") as stream:
    for line in stream:
        match = pattern.match(line.rstrip("\r\n"))
        if match:
            value = match.group(1).strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values.append(value)
if len(values) > 1:
    raise SystemExit(f"ERROR: duplicate {key} entries in .env; resolve them manually")
if values:
    print(values[0])
PY
}

vw_env_set_known() {
  local key="$1" value="$2"
  case "$key" in
    SIGNUPS_ALLOWED|VAULTWARDEN_IMAGE) ;;
    *) vw_die "Refusing to modify unsupported .env key '$key'." ;;
  esac
  if [[ "$key" == SIGNUPS_ALLOWED ]]; then
    [[ "$value" == true || "$value" == false ]] || vw_die "Refusing invalid value for $key."
  else
    [[ "$value" =~ ^vaultwarden/server:[0-9]+\.[0-9]+\.[0-9]+$ ]] || vw_die "Refusing invalid value for $key."
  fi
  python3 - "$VW_ENV_FILE" "$key" "$value" <<'PY'
import os, re, stat, sys, tempfile
path, key, value = sys.argv[1:]
if not os.path.isfile(path) or os.path.islink(path):
    raise SystemExit(f"ERROR: refusing to modify a missing, non-file, or symlink .env: {path}")
with open(path, "rb") as stream:
    original = stream.read()
original_stat = os.stat(path, follow_symlinks=False)
try:
    text = original.decode("utf-8")
except UnicodeDecodeError:
    raise SystemExit("ERROR: .env is not valid UTF-8; refusing to modify it")
pattern = re.compile(r"^\s*" + re.escape(key) + r"\s*=.*$")
lines = text.splitlines(keepends=True)
matches = [i for i, line in enumerate(lines) if pattern.match(line.rstrip("\r\n"))]
if len(matches) > 1:
    raise SystemExit(f"ERROR: duplicate {key} entries in .env; resolve them manually")
if matches:
    i = matches[0]
    ending = "\r\n" if lines[i].endswith("\r\n") else ("\n" if lines[i].endswith("\n") else "")
    lines[i] = f"{key}={value}{ending}"
else:
    if lines and not lines[-1].endswith(("\n", "\r")):
        lines[-1] += "\n"
    lines.append(f"{key}={value}\n")
mode = stat.S_IMODE(original_stat.st_mode)
fd, temporary = tempfile.mkstemp(prefix=".env.", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
        stream.writelines(lines)
        stream.flush()
        os.fsync(stream.fileno())
    if hasattr(os, "geteuid") and os.geteuid() == 0:
        os.chown(temporary, original_stat.st_uid, original_stat.st_gid)
    os.chmod(temporary, min(mode, 0o600))
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
  chmod 600 "$VW_ENV_FILE"
}

vw_check_signup_override() {
  [[ -e "$VW_CONFIG_FILE" ]] || return 0
  python3 - "$VW_CONFIG_FILE" <<'PY'
import json, os, sys
path = sys.argv[1]
if not os.path.isfile(path) or os.path.islink(path):
    raise SystemExit(f"ERROR: unexpected config.json type at {path}")
try:
    with open(path, encoding="utf-8") as stream:
        config = json.load(stream)
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"ERROR: cannot safely inspect Vaultwarden admin config.json: {exc}")
if not isinstance(config, dict):
    raise SystemExit("ERROR: unexpected config.json structure; refusing signup changes")
if "signups_allowed" in config or "signupsAllowed" in config:
    raise SystemExit("ERROR: config.json contains an admin-interface SIGNUPS_ALLOWED override. Review the admin setting manually; this helper will not change it.")
PY
}

vw_api_registration_state() {
  local expected_disabled="$1" body
  body="$(curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8080/api/config)" || return 1
  python3 -c '
import json, sys
expected = sys.argv[1] == "true"
try:
   data = json.load(sys.stdin)
except json.JSONDecodeError:
   raise SystemExit("ERROR: Vaultwarden /api/config returned invalid JSON")
if not isinstance(data, dict):
   raise SystemExit("ERROR: unexpected Vaultwarden /api/config response")
settings = data.get("settings", data)
if not isinstance(settings, dict):
   raise SystemExit("ERROR: unexpected Vaultwarden /api/config settings")
key = next((k for k in ("disableUserRegistration", "DisableUserRegistration") if k in settings), None)
if key is None or not isinstance(settings[key], bool):
   raise SystemExit("ERROR: /api/config did not provide a boolean disableUserRegistration value")
if settings[key] is not expected:
   raise SystemExit("ERROR: effective Vaultwarden registration status does not match the requested status")
  ' "$expected_disabled" <<<"$body"
}

vw_api_registration_closed() {
  vw_api_registration_state true
}

vw_api_registration_open() {
  vw_api_registration_state false
}

vw_service_running() {
 local id
 id="$(vw_compose ps -q vaultwarden 2>/dev/null)" || return 1
 [[ -n "$id" ]] || return 1
 [[ "$(vw_docker inspect --format '{{.State.Running}}' "$id" 2>/dev/null)" == true ]]
}

vw_docker() {
 if [[ "$(id -u)" -eq 0 ]]; then
   command docker "$@"
 else
   sudo docker "$@"
 fi
}

vw_wait_for_alive() {
 local attempt status
  for attempt in {1..30}; do
   status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 2 http://127.0.0.1:8080/alive 2>/dev/null || true)"
    [[ "$status" == 200 ]] && return 0
    sleep 2
  done
  return 1
}

vw_wait_for_https() {
 local url="$1" attempt status
 for attempt in {1..30}; do
   status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 "$url/alive" 2>/dev/null || true)"
   [[ "$status" == 200 ]] && return 0
   sleep 2
 done
 return 1
}

vw_check_linux_prerequisites() {
 [[ "$(uname -s)" == Linux ]] || vw_die "The installer runs only on Linux. Server commands are not supported on Windows/macOS."
 [[ "$(uname -m)" == aarch64 ]] || vw_die "A 64-bit ARM64 Linux system (aarch64) is required; found $(uname -m)."
 [[ -r /etc/os-release ]] || vw_die "Cannot identify the Linux distribution from /etc/os-release."
 # shellcheck disable=SC1091
 source /etc/os-release
 case "${ID:-}:${ID_LIKE:-}" in
   raspbian:*|debian:*|*:debian*) ;;
   *) vw_die "This setup supports Raspberry Pi OS/Debian-family Linux only; found ${PRETTY_NAME:-an unknown distribution}." ;;
 esac
 command -v systemctl >/dev/null 2>&1 || vw_die "systemd/systemctl is required."
 systemctl is-system-running >/dev/null 2>&1 || [[ "$(systemctl is-system-running 2>/dev/null || true)" == degraded ]] || vw_die "systemd is not running normally."
 command -v docker >/dev/null 2>&1 || vw_die "Docker Engine is missing. See docs/prerequisites.md."
 docker compose version >/dev/null 2>&1 || sudo docker compose version >/dev/null 2>&1 || vw_die "Docker Compose v2 is missing. See docs/prerequisites.md."
 command -v tailscale >/dev/null 2>&1 || vw_die "Tailscale CLI is missing. Install and sign in on the Pi first."
 command -v python3 >/dev/null 2>&1 || vw_die "Python 3 is needed to safely read Tailscale's JSON status."
 command -v curl >/dev/null 2>&1 || vw_die "curl is needed for local HTTP/HTTPS health checks."
 sudo -v || vw_die "sudo permission is required for Docker and Tailscale commands."
 sudo docker info >/dev/null 2>&1 || vw_die "Docker daemon is not reachable. Check 'sudo systemctl status docker' and docs/troubleshooting.md."
 docker compose version >/dev/null 2>&1 || sudo docker compose version >/dev/null 2>&1 || vw_die "Docker Compose v2 is required."
}

vw_check_loopback_port() {
 local port="$1"
 python3 - "$port" <<'PY'
import socket, sys
port = int(sys.argv[1])
sock = socket.socket()
try:
   sock.bind(("127.0.0.1", port))
except OSError as exc:
   raise SystemExit(f"ERROR: 127.0.0.1:{port} is already in use or unavailable ({exc}). Find the existing owner; this setup will not stop it.")
finally:
   sock.close()
PY
}

vw_check_tailscale_login() {
 local json
 json="$(tailscale status --json)" || vw_die "Tailscale status failed. Check 'tailscale status' and the Tailscale service."
 python3 -c '
import json, sys
try: data = json.load(sys.stdin)
except json.JSONDecodeError: raise SystemExit("ERROR: tailscale status --json did not return valid JSON")
if data.get("BackendState") != "Running":
   raise SystemExit("ERROR: Tailscale is not running and signed in. Check tailscale status.")
if data.get("Self", {}).get("Online") is False:
   raise SystemExit("ERROR: Tailscale reports this device offline.")
' <<<"$json" || vw_die "Tailscale must be logged in and running before setup."
}

vw_tailscale_dns_name() {
 local json
 json="$(tailscale status --json)" || return 1
 python3 -c '
import json, sys
try: data = json.load(sys.stdin)
except json.JSONDecodeError: raise SystemExit("ERROR: invalid Tailscale status JSON")
name = data.get("Self", {}).get("DNSName", "")
if not isinstance(name, str): raise SystemExit("ERROR: Tailscale Self.DNSName was not text")
print(name.rstrip("."))
' <<<"$json"
}

vw_tailscale_config_empty() {
 local mode="$1" output
 if [[ "$mode" == serve ]]; then
   output="$(sudo tailscale serve status --json 2>&1)" || return 1
 else
   output="$(sudo tailscale funnel status --json 2>&1)" || return 1
 fi
 python3 -c '
import json, sys
try: data = json.load(sys.stdin)
except json.JSONDecodeError: raise SystemExit("ERROR: status was not valid JSON")
if not isinstance(data, dict): raise SystemExit("ERROR: unexpected Tailscale status JSON shape")
for key in ("Web", "TCP", "AllowFunnel"):
   value = data.get(key)
   if value not in (None, {}, [], False):
       raise SystemExit(1)
' <<<"$output"
}

vw_check_serve_and_funnel_clear() {
 vw_tailscale_config_empty serve || vw_die "Tailscale Serve already has a route or its status could not be read. Review 'sudo tailscale serve status --json'; this setup will not reset or overwrite it."
 vw_tailscale_config_empty funnel || vw_die "Tailscale Funnel is active or its status could not be read. Review 'sudo tailscale funnel status --json'; this setup will not reset or modify it."
}

vw_confirm_serve_and_funnel_clear() {
 vw_tailscale_config_empty serve && vw_tailscale_config_empty funnel
}

vw_lock() {
 command -v flock >/dev/null 2>&1 || vw_die "flock is required for safe maintenance."
 install -d -o root -g root -m 700 "$VW_LOCK_DIR"
 exec 9>"$VW_LOCK_FILE"
 flock -n 9 || vw_die "Another backup, update, or restore appears to be in progress. Wait and try again."
 chmod 600 "$VW_LOCK_FILE"
}

vw_require_root() {
 [[ "$(id -u)" -eq 0 || "${VW_TEST_MODE:-}" == 1 ]] || vw_die "Run this maintenance command with sudo, for example: sudo bash scripts/$1"
}

vw_root_timer_config() {
 local config="${VW_ROOT_CONFIG:-/etc/vaultwarden-project-setup/backup.json}"
 [[ -r "$config" ]] || return 1
 python3 - "$config" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as stream:
   data = json.load(stream)
if not isinstance(data, dict) or not isinstance(data.get("project_dir"), str) or not isinstance(data.get("backup_dir"), str):
   raise SystemExit("ERROR: invalid root backup configuration")
print(data["project_dir"])
print(data["backup_dir"])
PY
}
