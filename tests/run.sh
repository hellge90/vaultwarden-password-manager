#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
PASS=0

pass() {
  printf 'ok - %s\n' "$1"
  PASS=$((PASS + 1))
}

expect_failure() {
  local label="$1" output="$2"
  shift 2
  if "$@" >"$output" 2>&1; then
    printf 'not ok - %s unexpectedly succeeded\n' "$label" >&2
    cat "$output" >&2
    exit 1
  fi
  pass "$label"
}

make_fixture() {
  local name="$1" fixture="$TMP/$1 with spaces"
  mkdir -p "$fixture/scripts"
  cp "$ROOT/install.sh" "$fixture/install.sh"
  cp "$ROOT/compose.yaml" "$fixture/compose.yaml"
  cp "$ROOT/scripts/"*.sh "$fixture/scripts/"
  printf '%s\n' "$fixture"
}

FIXTURE="$(make_fixture primary)"
mkdir -p "$FIXTURE/vw-data" "$TMP/mock-bin"
cat >"$FIXTURE/.env" <<'EOF'
VAULTWARDEN_IMAGE=vaultwarden/server:1.37.3
VAULTWARDEN_DOMAIN=https://pi.tailnet.ts.net
SIGNUPS_ALLOWED="false"
KEEP_THIS=value
EOF
chmod 600 "$FIXTURE/.env"

source "$FIXTURE/scripts/common.sh"
[[ "$VW_ROOT" == "$FIXTURE" ]] || { printf 'repository path with spaces was not resolved\n' >&2; exit 1; }
(
  cd /
  source "$FIXTURE/scripts/common.sh"
  [[ "$VW_ROOT" == "$FIXTURE" ]]
)
pass "repository path with spaces and independent working directory"

[[ "$(vw_env_read SIGNUPS_ALLOWED)" == false ]]
vw_env_set_known SIGNUPS_ALLOWED true
vw_env_set_known SIGNUPS_ALLOWED true
[[ "$(vw_env_read SIGNUPS_ALLOWED)" == true ]]
[[ "$(grep -c '^SIGNUPS_ALLOWED=' "$VW_ENV_FILE")" == 1 ]]
grep -q '^KEEP_THIS=value$' "$VW_ENV_FILE"
if [[ "$(uname -s)" == Linux ]]; then
  [[ "$(stat -c '%a' "$VW_ENV_FILE")" == 600 ]]
fi
pass "known .env updates are repeatable, restrictive, and preserve other settings"

mkdir -p "$TMP/mock-bin"
cat >"$TMP/mock-bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'signup=%s\nargs=%s\n' "${SIGNUPS_ALLOWED-unset}" "$*" >>"$DOCKER_LOG"
EOF
cat >"$TMP/mock-bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
cat >"$TMP/mock-bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${API_JSON:-}"
EOF
cat >"$TMP/mock-bin/tailscale" <<'EOF'
#!/usr/bin/env bash
case "$1:${2:-}:${3:-}:${4:-}" in
  status:--json::)
    if [[ -v TAILSCALE_JSON ]]; then printf '%s' "$TAILSCALE_JSON"; else printf '{}'; fi
    ;;
  serve:status:--json:)
    if [[ -v SERVE_JSON ]]; then printf '%s' "$SERVE_JSON"; else printf '%s' '{"Web":{},"AllowFunnel":{}}'; fi
    ;;
  funnel:status:--json:)
    if [[ -v FUNNEL_JSON ]]; then printf '%s' "$FUNNEL_JSON"; else printf '%s' '{"Web":{},"AllowFunnel":{}}'; fi
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TMP/mock-bin/"*
export PATH="$TMP/mock-bin:$PATH"
export DOCKER_LOG="$TMP/docker.log"
export SIGNUPS_ALLOWED=true VAULTWARDEN_IMAGE=evil VAULTWARDEN_DOMAIN=evil
if ! command -v flock >/dev/null 2>&1; then
  cat >"$TMP/mock-bin/flock" <<'EOF'
#!/usr/bin/env bash
[[ "${FLOCK_FORCE_FAIL:-0}" != 1 ]]
EOF
  chmod +x "$TMP/mock-bin/flock"
  export FLOCK_MOCK=1
fi
vw_compose config --quiet
grep -q '^signup=unset$' "$DOCKER_LOG"
grep -q -- "--project-directory $FIXTURE" "$DOCKER_LOG"
pass "Compose uses stable project/file identity and ignores inherited config values"

export API_JSON='{"settings":{"disableUserRegistration":true}}'
vw_api_registration_closed
expect_failure "effective open-registration response rejected for close verification" "$TMP/api.log" env API_JSON='{"settings":{"disableUserRegistration":false}}' bash -c 'source "$1/scripts/common.sh"; vw_api_registration_closed' _ "$FIXTURE"
export TAILSCALE_JSON='{"BackendState":"Running","Self":{"DNSName":"pi.example.ts.net."}}'
[[ "$(vw_tailscale_dns_name)" == pi.example.ts.net ]]
vw_check_tailscale_login
export TAILSCALE_JSON='{"BackendState":"Running","Self":{"DNSName":""}}'
[[ -z "$(vw_tailscale_dns_name)" ]]
pass "Tailscale DNS parsing handles trailing dots and absent names"

export SERVE_JSON='{"Web":{},"AllowFunnel":{}}' FUNNEL_JSON='{"Web":{},"AllowFunnel":{}}'
vw_check_serve_and_funnel_clear
expect_failure "existing Serve route detected without reset" "$TMP/serve.log" env SERVE_JSON='{"Web":{"pi.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}' bash -c 'source "$1/scripts/common.sh"; vw_check_serve_and_funnel_clear' _ "$FIXTURE"
expect_failure "existing Funnel route detected without reset" "$TMP/funnel.log" env FUNNEL_JSON='{"Web":{"pi.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}' bash -c 'source "$1/scripts/common.sh"; vw_check_serve_and_funnel_clear' _ "$FIXTURE"
pass "Serve and Funnel conflicts fail closed"

printf '{"signups_allowed":true}\n' >"$VW_CONFIG_FILE"
expect_failure "admin signup override blocks helper changes" "$TMP/admin.log" bash -c 'source "$1/scripts/common.sh"; vw_check_signup_override' _ "$FIXTURE"
rm "$VW_CONFIG_FILE"

expect_failure "unsupported server OS rejected" "$TMP/os.log" bash -c 'source "$1/scripts/common.sh"; uname(){ printf MINGW; }; vw_check_linux_prerequisites' _ "$FIXTURE"
expect_failure "non-ARM64 architecture rejected" "$TMP/arch.log" bash -c 'source "$1/scripts/common.sh"; uname(){ if [[ "$1" == -s ]]; then printf Linux; else printf x86_64; fi; }; vw_check_linux_prerequisites' _ "$FIXTURE"
expect_failure "missing prerequisite command reported" "$TMP/dependency.log" bash -c 'source "$1/scripts/common.sh"; uname(){ if [[ "$1" == -s ]]; then printf Linux; else printf aarch64; fi; }; PATH="$2"; vw_check_linux_prerequisites' _ "$FIXTURE" "$TMP/empty-path"
pass "OS, architecture, and missing-dependency checks reject unsupported hosts"

run_install_scenario() {
  local scenario="$1" fixture="$TMP/install-$1" events="$TMP/install-$1.log"
  mkdir -p "$fixture"
  cp "$ROOT/install.sh" "$fixture/install.sh"
  cp "$ROOT/compose.yaml" "$fixture/compose.yaml"
  mkdir "$fixture/scripts"
  cp "$ROOT/scripts/"*.sh "$fixture/scripts/"
  env SCENARIO="$scenario" EVENT_LOG="$events" bash "$ROOT/tests/install-driver.sh" "$fixture" "$events"
}

for scenario in pull-fail health-fail serve-conflict funnel-conflict; do
  expect_failure "installer $scenario path" "$TMP/install-$scenario.out" run_install_scenario "$scenario"
done
grep -q '^SIGNUPS_ALLOWED=false$' "$TMP/install-health-fail/.env"
if grep -q '^sudo tailscale serve ' "$TMP/install-health-fail.log"; then
  printf 'installer configured Serve after failed health check\n' >&2
  exit 1
fi
pass "failed pull/health and Serve/Funnel conflicts do not report success or configure a route"

for scenario in no-dns route-race https-fail success; do
  fixture="$TMP/install-$scenario"
  if [[ "$scenario" == no-dns ]]; then
    mkdir -p "$fixture/scripts"
    cp "$ROOT/install.sh" "$fixture/install.sh"
    cp "$ROOT/compose.yaml" "$fixture/compose.yaml"
    cp "$ROOT/scripts/"*.sh "$fixture/scripts/"
    if env DNS_NAME= EVENT_LOG="$TMP/$scenario.log" bash "$ROOT/tests/install-driver.sh" "$fixture" "$TMP/$scenario.log" >"$TMP/$scenario.out" 2>&1; then
      printf 'no-DNS installer case unexpectedly succeeded\n' >&2
      exit 1
    fi
    [[ ! -e "$fixture/.env" && ! -e "$fixture/vw-data" ]]
    pass "absent Tailscale DNS name stops before creating files"
  elif [[ "$scenario" == success ]]; then
    run_install_scenario "$scenario"
    grep -q '^SIGNUPS_ALLOWED=false$' "$fixture/.env"
    if [[ "$(uname -s)" == Linux ]]; then
      [[ "$(stat -c '%a' "$fixture/.env")" == 600 ]]
    fi
    grep -q '^sudo tailscale serve --bg http://127.0.0.1:8080$' "$TMP/install-$scenario.log"
    pass "mock installer success pins config and keeps registration closed"
  else
    expect_failure "installer $scenario path" "$TMP/$scenario.out" run_install_scenario "$scenario"
  fi
done

fixture="$TMP/install-rerun"
mkdir -p "$fixture/scripts" "$fixture/vw-data"
cp "$ROOT/install.sh" "$fixture/install.sh"
cp "$ROOT/compose.yaml" "$fixture/compose.yaml"
cp "$ROOT/scripts/"*.sh "$fixture/scripts/"
printf 'keep-this-config\n' >"$fixture/.env"
printf 'keep-this-data\n' >"$fixture/vw-data/sentinel"
EVENT_LOG="$TMP/rerun.log" bash "$ROOT/tests/install-driver.sh" "$fixture" "$TMP/rerun.log"
grep -q '^read-only-status ' "$TMP/rerun.log"
[[ "$(cat "$fixture/.env")" == keep-this-config ]]
[[ "$(cat "$fixture/vw-data/sentinel")" == keep-this-data ]]
pass "installer rerun is read-only and preserves config and vault data"

BACKUP_FIXTURE="$TMP/backup fixture"
mkdir -p "$BACKUP_FIXTURE/scripts" "$BACKUP_FIXTURE/vw-data" "$BACKUP_FIXTURE/backups"
cp "$ROOT/scripts/common.sh" "$ROOT/scripts/backup.sh" "$ROOT/scripts/update.sh" "$BACKUP_FIXTURE/scripts/"
cp "$ROOT/compose.yaml" "$BACKUP_FIXTURE/compose.yaml"
printf 'VAULTWARDEN_IMAGE=vaultwarden/server:1.37.3\nSIGNUPS_ALLOWED=false\n' >"$BACKUP_FIXTURE/.env"
python3 - "$BACKUP_FIXTURE/vw-data/db.sqlite3" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute("CREATE TABLE restore_test (value TEXT)")
    db.execute("INSERT INTO restore_test VALUES ('ok')")
PY
printf 'important older archive\n' >"$BACKUP_FIXTURE/backups/older.tar.gz"

if command -v flock >/dev/null 2>&1; then
backup_once() {
  local name="$1" state="$2" scenario="${3:-}"
  local dest="$TMP/$name-destination" events="$TMP/$name-events" state_file="$TMP/$name-state"
  mkdir "$dest"
  chmod 700 "$dest"
  printf 'keep older verified archive\n' >"$dest/older.tar.gz"
  printf '%s\n' "$state" >"$state_file"
  env EVENTS="$events" FAIL_STOP="${FAIL_STOP:-0}" HEALTH_FAIL="${HEALTH_FAIL:-0}" LOCK_DIR="$TMP/$name-lockdir" LOCK_FILE="$TMP/$name.lock" bash "$ROOT/tests/backup-driver.sh" "$BACKUP_FIXTURE" "$dest" "$state_file"
}

backup_once backup-running running
RUNNING_ARCHIVE="$(find "$TMP/backup-running-destination" -maxdepth 1 -name 'vaultwarden-*.tar.gz' -print -quit)"
[[ -n "$RUNNING_ARCHIVE" && "$(cat "$TMP/backup-running-state")" == running ]]
[[ -f "$TMP/backup-running-destination/older.tar.gz" ]]
[[ -z "$(find "$TMP/backup-running-destination" -maxdepth 1 \( -name '*.tmp.*' -o -name '.vaultwarden-metadata.*' \) -print -quit)" ]]
gzip -t "$RUNNING_ARCHIVE"
tar -tzf "$RUNNING_ARCHIVE" >"$TMP/archive-members.txt"
grep -q '^vw-data/' "$TMP/archive-members.txt"
grep -q '^.env$' "$TMP/archive-members.txt"
grep -q '^compose.yaml$' "$TMP/archive-members.txt"
grep -q '^backup-metadata.json$' "$TMP/archive-members.txt"
python3 "$ROOT/tests/restore-tests.py" "$RUNNING_ARCHIVE"
pass "backup is atomic, integrity checked, contains deployment/version metadata, and restarts service"

inside_dest="$BACKUP_FIXTURE/vw-data/backup-destination"
printf 'running\n' >"$TMP/backup-inside-state"
expect_failure "backup destination inside vw-data is rejected" "$TMP/backup-inside.out" env EVENTS="$TMP/backup-inside-events" LOCK_DIR="$TMP/backup-inside-lockdir" LOCK_FILE="$TMP/backup-inside.lock" bash "$ROOT/tests/backup-driver.sh" "$BACKUP_FIXTURE" "$inside_dest" "$TMP/backup-inside-state"
[[ ! -e "$inside_dest" && "$(cat "$TMP/backup-inside-state")" == running ]]
pass "backup refuses recursive inclusion before creating a destination inside the data tree"

backup_once backup-stopped stopped
[[ "$(cat "$TMP/backup-stopped-state")" == stopped ]]
[[ ! -e "$TMP/backup-stopped-events" ]] || ! grep -q '^start vaultwarden$' "$TMP/backup-stopped-events"
pass "backup preserves an already-stopped service"

mkdir "$TMP/failing-bin"
cat >"$TMP/failing-bin/tar" <<'EOF'
#!/bin/sh
exit 17
EOF
chmod +x "$TMP/failing-bin/tar"
fail_dest="$TMP/backup-failure-destination"
mkdir "$fail_dest"
chmod 700 "$fail_dest"
printf 'keep old archive\n' >"$fail_dest/older.tar.gz"
printf 'running\n' >"$TMP/backup-failure-state"
if env PATH="$TMP/failing-bin:$PATH" EVENTS="$TMP/backup-failure-events" LOCK_DIR="$TMP/backup-failure-lockdir" LOCK_FILE="$TMP/backup-failure.lock" bash "$ROOT/tests/backup-driver.sh" "$BACKUP_FIXTURE" "$fail_dest" "$TMP/backup-failure-state" >"$TMP/backup-failure.out" 2>&1; then
  printf 'failed archive creation unexpectedly reported success\n' >&2
  exit 1
fi
[[ "$(cat "$TMP/backup-failure-state")" == running ]]
[[ -f "$fail_dest/older.tar.gz" ]]
[[ -z "$(find "$fail_dest" -maxdepth 1 -name 'vaultwarden-*.tar.gz' -print -quit)" ]]
[[ -z "$(find "$fail_dest" -maxdepth 1 \( -name '*.tmp.*' -o -name '.vaultwarden-metadata.*' \) -print -quit)" ]]
grep -q '^start vaultwarden$' "$TMP/backup-failure-events"
pass "failed archive is not published or pruned and service is restarted"

stop_dest="$TMP/backup-stop-failure-destination"
mkdir "$stop_dest"
chmod 700 "$stop_dest"
printf 'running\n' >"$TMP/backup-stop-failure-state"
if env FAIL_STOP=1 EVENTS="$TMP/backup-stop-failure-events" LOCK_DIR="$TMP/backup-stop-failure-lockdir" LOCK_FILE="$TMP/backup-stop-failure.lock" bash "$ROOT/tests/backup-driver.sh" "$BACKUP_FIXTURE" "$stop_dest" "$TMP/backup-stop-failure-state" >"$TMP/backup-stop-failure.out" 2>&1; then
  printf 'failed service stop unexpectedly reported success\n' >&2
  exit 1
fi
[[ "$(cat "$TMP/backup-stop-failure-state")" == running ]]
grep -q '^start vaultwarden$' "$TMP/backup-stop-failure-events"
pass "partial stop failure restarts a service that was originally running"

health_dest="$TMP/backup-health-failure-destination"
mkdir "$health_dest"
chmod 700 "$health_dest"
printf 'running\n' >"$TMP/backup-health-failure-state"
health_marker="$BACKUP_FIXTURE/backup-running"
if env HEALTH_FAIL=1 EVENTS="$TMP/backup-health-failure-events" LOCK_DIR="$TMP/backup-health-failure-lockdir" LOCK_FILE="$TMP/backup-health-failure.lock" BACKUP_STATE_FILE="$health_marker" bash "$ROOT/tests/backup-driver.sh" "$BACKUP_FIXTURE" "$health_dest" "$TMP/backup-health-failure-state" >"$TMP/backup-health-failure.out" 2>&1; then
  printf 'failed post-backup health check unexpectedly reported success\n' >&2
  exit 1
fi
grep -q 'not healthy' "$TMP/backup-health-failure.out"
[[ "$(cat "$TMP/backup-health-failure-state")" == running ]]
[[ -f "$health_marker" ]]
pass "failed post-backup health check is surfaced as failure"
if env EVENTS="$TMP/backup-interrupted-events" LOCK_DIR="$TMP/backup-interrupted-lockdir" LOCK_FILE="$TMP/backup-interrupted.lock" BACKUP_STATE_FILE="$health_marker" bash "$ROOT/tests/backup-driver.sh" "$BACKUP_FIXTURE" "$health_dest" "$TMP/backup-health-failure-state" >"$TMP/backup-interrupted.out" 2>&1; then
  printf 'backup ignored an unresolved interrupted-state marker\n' >&2
  exit 1
fi
grep -q 'prior backup was interrupted' "$TMP/backup-interrupted.out"
rm -f "$health_marker"
pass "a later backup refuses to proceed while an interrupted-state marker remains"

busy_dest="$TMP/backup-lock-destination"
mkdir "$busy_dest"
chmod 700 "$busy_dest"
printf 'running\n' >"$TMP/backup-lock-state"
busy_lock="$TMP/backup-busy.lock"
exec 8>"$busy_lock"
flock -n 8
expect_failure "maintenance lock blocks concurrent backup" "$TMP/backup-lock.out" env FLOCK_FORCE_FAIL=1 EVENTS="$TMP/backup-lock-events" LOCK_DIR="$TMP/backup-lockdir" LOCK_FILE="$busy_lock" bash "$ROOT/tests/backup-driver.sh" "$BACKUP_FIXTURE" "$busy_dest" "$TMP/backup-lock-state"
[[ "$(cat "$TMP/backup-lock-state")" == running ]]
exec 8>&-
pass "shared nonblocking maintenance lock"
else
  pass "backup execution tests skipped on this host (GNU flock is unavailable)"
fi

signup_fixture="$TMP/signup fixture"
mkdir -p "$signup_fixture/scripts" "$signup_fixture/vw-data"
cp "$ROOT/scripts/"*.sh "$signup_fixture/scripts/"
cp "$ROOT/compose.yaml" "$signup_fixture/compose.yaml"
printf 'VAULTWARDEN_IMAGE=vaultwarden/server:1.37.3\nVAULTWARDEN_DOMAIN=https://pi.example.ts.net\nSIGNUPS_ALLOWED=false\n' >"$signup_fixture/.env"
cp "$signup_fixture/.env" "$signup_fixture/.env.original"
bash "$ROOT/tests/signup-driver.sh" "$signup_fixture" close "$TMP/signup-close.log"
cmp "$signup_fixture/.env" "$signup_fixture/.env.original"
[[ ! -s "$TMP/signup-close.log" ]]
pass "closing signups is idempotent when the effective setting is already closed"
env ANSWER=OPEN bash "$ROOT/tests/signup-driver.sh" "$signup_fixture" open "$TMP/signup-open.log"
grep -q '^SIGNUPS_ALLOWED=true$' "$signup_fixture/.env"
grep -q '^up -d --no-deps --force-recreate vaultwarden$' "$TMP/signup-open.log"
bash "$ROOT/tests/signup-driver.sh" "$signup_fixture" close "$TMP/signup-close-again.log"
grep -q '^SIGNUPS_ALLOWED=false$' "$signup_fixture/.env"
grep -q '^up -d --no-deps --force-recreate vaultwarden$' "$TMP/signup-close-again.log"
pass "signup helper opens only after confirmation and closes with service recreation"
before="$(cat "$signup_fixture/.env")"
expect_failure "unconfirmed signup opening is rejected" "$TMP/signup-denied.log" env ANSWER=NO bash "$ROOT/tests/signup-driver.sh" "$signup_fixture" open "$TMP/signup-denied-events.log"
[[ "$(cat "$signup_fixture/.env")" == "$before" ]]

update_events="$TMP/update-events"
env EVENTS="$update_events" bash "$ROOT/tests/update-driver.sh" "$BACKUP_FIXTURE" "$update_events" 1.37.3
[[ "$(sed -n '1p' "$update_events")" == lock ]]
[[ "$(sed -n '2p' "$update_events")" == 'docker manifest inspect vaultwarden/server:1.37.3' ]]
[[ "$(sed -n '3p' "$update_events")" == 'backup lock-held=true' ]]
grep -q '^set VAULTWARDEN_IMAGE=vaultwarden/server:1.37.3$' "$update_events"
grep -q '^compose pull vaultwarden$' "$update_events"
pass "update verifies ARM64 and backs up under the already-held lock before selected-tag pull"
expect_failure "prerelease update tag rejected" "$TMP/update-invalid.log" env EVENTS="$TMP/update-invalid-events" bash "$ROOT/tests/update-driver.sh" "$BACKUP_FIXTURE" "$TMP/update-invalid-events" latest
expect_failure "image without ARM64 rejected" "$TMP/update-arm.log" env NO_ARM64=1 EVENTS="$TMP/update-arm-events" bash "$ROOT/tests/update-driver.sh" "$BACKUP_FIXTURE" "$TMP/update-arm-events" 1.37.4
expect_failure "failed updated-service health is not success" "$TMP/update-health.log" env HEALTH_FAIL=1 EVENTS="$TMP/update-health-events" bash "$ROOT/tests/update-driver.sh" "$BACKUP_FIXTURE" "$TMP/update-health-events" 1.37.4
if grep -q 'Vaultwarden is responding after update' "$TMP/update-health.log"; then
  printf 'update health failure printed a success message\n' >&2
  exit 1
fi

printf '\nAll %d local mock checks passed.\n' "$PASS"
