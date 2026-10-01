# Backups, restore tests, and updates

Vaultwarden stores the SQLite database, SQLite write-ahead log (WAL), files,
attachments, Sends, configuration, and cryptographic keys under `vw-data/`.
The backup script briefly stops only the `vaultwarden` Compose service so the
whole directory is archived consistently. It never runs `compose down -v`.
If the service was already stopped, it stays stopped. If it was running, the
script attempts to restart it and checks local health after both successful
and failed backup attempts.

Backups are **not additionally encrypted**. They contain sensitive vault
data, attachments, keys, `.env`, the Compose file, and image/version metadata.
The file and directory permissions are restrictive, but do not treat that as
encryption. Store archives on protected storage and arrange off-device copies
yourself. Consider encrypting the archive with a tool and key-management
process you have reviewed before moving it off the Pi. Nothing in this project
uploads backups. A backup on the same SD card or SSD will not survive failure
of that device.

The first backup has not been made or tested just because the scripts exist.
After setup, run one manually, inspect its exact printed filename, verify it,
and copy it to protected off-device storage.

## Make and inspect a manual backup

Run on the Pi from the project directory. `sudo` may prompt for your Linux
account password; the characters are invisible while typing.

```bash
sudo bash scripts/backup.sh
```

By default, the archive is written to the ignored `backups/` folder within
this repository. To select a different destination, pass an existing or
creatable directory path:

```bash
sudo bash scripts/backup.sh "/path/to/protected-backup-disk/vaultwarden"
```

Use a mounted, protected disk and replace the example path with its actual
mount point. The script checks destination writability and free space before
stopping the service. It creates a unique temporary archive, checks gzip and
tar integrity, then atomically renames the verified archive to its final
timestamped name. It does not prune old archives.

Copy the exact archive path shown after `Verified archive created:`:

```bash
sudo gzip -t "/path/to/backups/vaultwarden-YYYYMMDDTHHMMSSZ.tar.gz"
sudo tar -tzf "/path/to/backups/vaultwarden-YYYYMMDDTHHMMSSZ.tar.gz"
```

Success means the archive can be decompressed and its member list can be read;
it does not prove you have completed a restore or tested an account login.
Use the matching real filename, not the `YYYY...` example.

## Optional daily backup timer

The optional systemd timer is disabled unless you deliberately opt in. It
runs daily at **03:00 in the Pi's system timezone**, uses persistent catch-up
after downtime, and saves archives to `backups/`. When you opt in, the
installer displays the current timezone before asking for confirmation.
It installs reviewed copies of `common.sh` and `backup.sh` as root-owned
executables under `/usr/local/lib/vaultwarden-project-setup/` and a root-only
configuration file under `/etc/vaultwarden-project-setup/`. The scheduled
helper reads `.env` as Compose configuration; it never executes or sources
`.env` as shell code. It does not remove old archives or make an off-device
copy for you.

Enable it from the project folder:

```bash
sudo bash scripts/install-backup-timer.sh
```

Type `ENABLE` only after confirming the displayed timezone and backup
destination. The setup is idempotent and refuses to replace unrelated files
or units. It does not make an initial archive as part of timer installation.

Check the timer, start one on-demand run, and read its logs:

```bash
sudo systemctl list-timers vaultwarden-backup.timer --all
sudo systemctl status vaultwarden-backup.timer --no-pager
sudo systemctl start vaultwarden-backup.service
sudo systemctl status vaultwarden-backup.service --no-pager
sudo journalctl -u vaultwarden-backup.service --since today --no-pager
```

Confirm an archive was printed in the log, then run the integrity commands
above and arrange a protected off-device copy. A timer trigger during Pi
downtime is caught up after boot, but cannot protect against a power loss
during an active write or an unavailable/full backup disk. If the service was
unexpectedly left stopped after a power loss, inspect
`sudo bash scripts/status.sh` and the Docker logs before deciding whether to
start it. When a backup stops a previously running service, it records a
root-only state marker under `/var/lib/vaultwarden-project-setup/` before
stopping it. If power is lost or recovery health checks fail, the next backup
refuses to proceed while that marker exists; `scripts/status.sh` also warns
about it. Check the marker and service first:

```bash
sudo bash scripts/status.sh
STATE_FILE="$(bash -c 'source scripts/common.sh; printf "%s" "$VW_BACKUP_STATE_FILE"')"
sudo ls -l "$STATE_FILE"
```

Only after confirming no backup is active, the service is healthy, and you
have reviewed the prior outcome, preserve the marker under a reviewed name so
future backups can proceed:

```bash
sudo mv -- "$STATE_FILE" "$STATE_FILE.reviewed-$(date -u +%Y%m%dT%H%M%SZ)"
```

No old archive cleanup is implemented or enabled.

## Test a restore in an isolated folder first

Never experiment against the production `vw-data/`. Pick a verified archive
and an **empty, separate** test directory. The following creates a new
private folder in your home directory:

```bash
TEST_DIR="$(mktemp -d "$HOME/vaultwarden-restore-test.XXXXXX")"
chmod 700 "$TEST_DIR"
printf 'Isolated test folder: %s\n' "$TEST_DIR"
mkdir -m 700 "$TEST_DIR/extracted"
```

Verify integrity before extraction:

```bash
sudo gzip -t "/path/to/backups/vaultwarden-YYYYMMDDTHHMMSSZ.tar.gz"
sudo tar -tzf "/path/to/backups/vaultwarden-YYYYMMDDTHHMMSSZ.tar.gz"
```

Extract only into the new empty folder with this Python 3 standard-library
snippet. It rejects absolute paths, `..`, duplicate paths, links, devices,
and anything outside the expected archive layout before creating files. It
does not touch production data. Replace the archive example with the exact
path:

```bash
sudo python3 - "/path/to/backups/vaultwarden-YYYYMMDDTHHMMSSZ.tar.gz" "$TEST_DIR/extracted" <<'PY'
import os, pathlib, sys, tarfile
archive, destination = sys.argv[1:]
root = pathlib.Path(destination).resolve()
if any(root.iterdir()):
    raise SystemExit("Refusing to extract into a non-empty test directory")
allowed_files = {".env", "compose.yaml", "backup-metadata.json"}
seen = set()
with tarfile.open(archive, "r:gz") as tf:
    members = tf.getmembers()
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        parts = path.parts
        if path.is_absolute() or not parts or any(part in ("", ".", "..") for part in parts):
            raise SystemExit(f"Unsafe archive path: {member.name!r}")
        if parts[0] not in ("vw-data", *allowed_files):
            raise SystemExit(f"Unexpected archive entry: {member.name!r}")
        if parts[0] in allowed_files and len(parts) != 1:
            raise SystemExit(f"Unexpected nested config entry: {member.name!r}")
        normalized = path.as_posix().rstrip("/")
        if normalized in seen or not (member.isdir() or member.isfile()):
            raise SystemExit(f"Duplicate or unsupported archive entry: {member.name!r}")
        seen.add(normalized)
    if not {"vw-data", ".env", "compose.yaml"}.issubset(seen):
        raise SystemExit("Archive is missing required data or deployment files")
    for member in members:
        normalized = pathlib.PurePosixPath(member.name).as_posix().rstrip("/")
        target = (root / pathlib.Path(*pathlib.PurePosixPath(normalized).parts)).resolve()
        if target != root and root not in target.parents:
            raise SystemExit(f"Archive path escapes the test directory: {member.name!r}")
        if member.isdir():
            target.mkdir(mode=0o700, parents=True, exist_ok=True)
        else:
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            source = tf.extractfile(member)
            if source is None:
                raise SystemExit(f"Could not read archive member: {member.name!r}")
            with source, target.open("xb") as output:
                while chunk := source.read(1024 * 1024):
                    output.write(chunk)
            os.chmod(target, 0o600)
print(f"Safely extracted into {root}")
PY
```

Check layout and SQLite integrity without opening production:

```bash
test -f "$TEST_DIR/extracted/vw-data/db.sqlite3"
test -f "$TEST_DIR/extracted/.env"
python3 - "$TEST_DIR/extracted/vw-data/db.sqlite3" <<'PY'
import sqlite3, sys
from pathlib import Path
uri = Path(sys.argv[1]).resolve().as_uri() + "?mode=ro"
db = sqlite3.connect(uri, uri=True)
try:
    result = db.execute("PRAGMA integrity_check").fetchone()
finally:
    db.close()
if result != ("ok",):
    raise SystemExit(f"SQLite integrity check failed: {result}")
print("SQLite integrity check: ok")
PY
```

For a functional test, create a temporary Compose file next to the extracted
copy with a **separate project name**, a loopback-only test port, and
registration closed. Do not use the production Compose project name, port
8080, Serve, a backup timer, or an open-signup helper. Read the image tag from
the archive as text, not shell code:

```bash
IMAGE="$(python3 - "$TEST_DIR/extracted/.env" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
values = re.findall(r"^VAULTWARDEN_IMAGE=(vaultwarden/server:[0-9]+\.[0-9]+\.[0-9]+)$", text, re.M)
if len(values) != 1:
    raise SystemExit("Archive .env does not contain exactly one numeric stable Vaultwarden image tag")
print(values[0])
PY
)"
cat >"$TEST_DIR/extracted/restore-test.yaml" <<EOF
services:
  vaultwarden:
    image: "$IMAGE"
    restart: "no"
    ports:
      - "127.0.0.1:18080:80"
    environment:
      DOMAIN: "http://127.0.0.1:18080"
      SIGNUPS_ALLOWED: "false"
      SIGNUPS_VERIFY: "false"
      SIGNUPS_DOMAINS_WHITELIST: ""
      INVITATIONS_ALLOWED: "false"
    volumes:
      - ./vw-data:/data
EOF
TEST_PROJECT="vw-restore-test-$(date +%s)"
python3 - <<'PY'
import socket
sock = socket.socket()
try:
    sock.bind(("127.0.0.1", 18080))
except OSError as exc:
    raise SystemExit(f"Choose another unused loopback-only test port instead of 18080: {exc}")
finally:
    sock.close()
PY
sudo docker compose --project-directory "$TEST_DIR/extracted" --project-name "$TEST_PROJECT" --env-file "$TEST_DIR/extracted/.env" -f "$TEST_DIR/extracted/restore-test.yaml" up -d
curl --fail --show-error http://127.0.0.1:18080/alive
```

If the restored test vault can be logged into using a client on the Pi, verify
sample entries and attachment behavior without copying credentials into a
command or log. The test uses plain HTTP only on the Pi loopback and is not a
Tailscale route. When finished, stop only the temporary test project, without
removing its data volume:

```bash
sudo docker compose --project-directory "$TEST_DIR/extracted" --project-name "$TEST_PROJECT" --env-file "$TEST_DIR/extracted/.env" -f "$TEST_DIR/extracted/restore-test.yaml" down
```

Keep the isolated test copy until you are satisfied with the test. Do not
mistake a successful archive listing for a tested restore.

## Production restore: deliberate, controlled recovery only

A production restore replaces the live vault's data and can lose newer
changes. Do it only after you have identified the right archive, completed
the isolated restore test above, and explicitly decided to restore it. Stop
and ask the vault owner before proceeding if you are not certain.

1. Make a **fresh pre-restore backup** and verify its gzip/tar integrity.
2. Verify that the chosen archive's app version is compatible with that
   backup's SQLite schema. Do not assume a database migrated by a newer image
   can be safely opened by an older image.
3. Stop the production service only; do not remove containers, volumes, or
   `vw-data/`:

   ```bash
   sudo env RESTORE_TEST_DIR="$TEST_DIR/extracted" bash -c 'cd "$1"; source scripts/common.sh; vw_lock; exec bash -i' _ "$PWD"
   ```

   This opens a root shell while holding the same maintenance lock used by the
   backup/update scripts. Keep this shell open through the restore; exiting it
   releases the lock. In that shell, run the following to check status and
   stop the service with the same project identity and environment safeguards:

   ```bash
   PROJECT_ROOT="$(pwd -P)"
   source scripts/common.sh
   bash scripts/status.sh
   vw_compose stop vaultwarden
   ```

4. In that root shell, set the project and restored-test paths, then confirm
   the app version recorded in the validated archive. The code reads JSON and
   `.env` as data; it does not execute `.env`:

   ```bash
   PROJECT_ROOT="$(pwd -P)"
   RESTORE_DIR="$RESTORE_TEST_DIR"
   ARCHIVE="/path/to/backups/vaultwarden-YYYYMMDDTHHMMSSZ.tar.gz"
   IMAGE="$(python3 - "$ARCHIVE" <<'PY'
   import json, re, sys, tarfile
   with tarfile.open(sys.argv[1], "r:gz") as archive:
       metadata = json.load(archive.extractfile("backup-metadata.json"))
   image = metadata.get("vaultwarden_image", "")
   if not re.fullmatch(r"vaultwarden/server:[0-9]+\.[0-9]+\.[0-9]+", image):
       raise SystemExit("Archive metadata does not identify one stable Vaultwarden image")
   print(image)
   PY
   )"
   printf 'Archive image: %s\n' "$IMAGE"
   ```

   Replace `ARCHIVE` with the exact verified archive. Confirm this version is
   compatible with the archive data and your chosen recovery. Stop if it
   requires a risky downgrade.
5. Confirm the restored data has no signup override. Set the known settings
   through the safe helper, preserving all other `.env` entries, then save
   the existing data directory with a new name before copying the restored
   data:

   ```bash
   source scripts/common.sh
   vw_check_signup_override
   vw_env_set_known VAULTWARDEN_IMAGE "$IMAGE"
   vw_env_set_known SIGNUPS_ALLOWED false
   STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
   sudo mv -- "$PROJECT_ROOT/vw-data" "$PROJECT_ROOT/vw-data.before-restore-$STAMP"
   sudo cp -a -- "$RESTORE_DIR/vw-data" "$PROJECT_ROOT/vw-data"
   ```

   If signup-override inspection reports a value, stop and resolve it
   deliberately; do not start the service with registration potentially open.
   Do not delete the preserved directory or the pre-restore archive.
6. Start only the Vaultwarden service and verify its local health and closed
   registration state:

   ```bash
   vw_compose up -d --no-deps --force-recreate vaultwarden
   curl --fail --show-error http://127.0.0.1:8080/alive
   vw_api_registration_closed
   ```

7. Sign in with a known test account, verify an attachment, and check a client
   sync. Keep both the pre-restore copy and the original data directory until
   the owner confirms recovery.

The ordinary backup, update, and restore maintenance operations share a
nonblocking system lock. Do not run a restore concurrently with an update or
backup. The documented production procedure is intentionally manual; there is
no automated production restore or automatic rollback.

## Updating

Update only after you choose a **stable numeric release tag** from the
[official Vaultwarden releases](https://github.com/dani-garcia/vaultwarden/releases).
The script verifies that the official image manifest has a Linux ARM64 image,
creates and verifies a pre-update archive, pulls only the selected tag,
recreates only the service using the same project identity, and checks local
health. For example, replace `1.37.3` with the stable release you selected:

```bash
sudo bash scripts/update.sh 1.37.3
```

The script does not use `latest`, `testing`, Watchtower, auto-updates, or
automatic rollback. Database migrations can make it unsafe to switch straight
back to an older image. If the new service fails its health check, retain the
archive and follow the coordinated recovery steps above instead of changing
the image tag casually. Test login, attachments, and client sync after an
update.
