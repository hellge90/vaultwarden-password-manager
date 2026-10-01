# Troubleshooting

Start with read-only checks and preserve `vw-data/`, `.env`, and all backup
archives. From the project folder on the Pi:

```bash
bash scripts/status.sh
bash -c 'source scripts/common.sh; vw_compose ps'
bash -c 'source scripts/common.sh; vw_compose logs --tail 80 vaultwarden'
```

Logs may contain private service details. Before sharing them, redact domains,
usernames, email addresses, tokens, IPs, and any other private values. Never
share passwords, `.env`, a database, a CSV export, a full config file, or
authentication tokens.

## Common checks

- **`bash` or `sudo` command not found:** These server scripts require Linux
  Bash and sudo on the Pi. Do not run them in a Windows/macOS terminal.
  `sudo` password input is invisible. Stop if you do not have authorized
  administrator access.
- **Docker permission denied / daemon not responding:** Check `sudo docker
  info` and `sudo systemctl status docker --no-pager`. Follow the
  [prerequisites guide](prerequisites.md); do not add yourself to the Docker
  group as a quick fix.
- **Compose v2 missing:** Check `sudo docker compose version`. Install the
  official Compose plugin only after reviewing the current Docker instructions
  and any existing Docker setup.
- **Port 8080 is already in use:** Do not stop the process or change the
  binding blindly. Identify its owner first. This project requires the local
  loopback address `127.0.0.1:8080`; it must not become a LAN-facing port.
- **Tailscale is offline or signed out:** Run `tailscale status` and check the
  host Tailscale service. Sign in through the authorized Tailscale workflow.
  This project does not reset or reinstall Tailscale.
- **No DNS name / HTTPS certificate warning:** Check MagicDNS and HTTPS
  certificate settings in the Tailscale admin console. If the installer
  printed an approval link supplied by Tailscale, open only that link on a
  Tailscale-connected device. Allow DNS/certificate provisioning time and
  check the Pi's clock with `timedatectl`. Never ignore a certificate warning
  or switch to HTTP/IP in the client.
- **Existing Serve or Funnel configuration:** The installer stops rather
  than resetting routes. Review `sudo tailscale serve status --json` and
  `sudo tailscale funnel status --json` with the tailnet administrator. Do not
  run `tailscale serve reset` or `tailscale funnel reset` to make this setup
  continue.
- **Wrong client URL:** Use the exact HTTPS `*.ts.net` URL printed by the
  installer. Select the self-hosted server option in the official client.
  Connect the client to Tailscale before signing in or syncing.
- **Signups won't close/open:** Check the result of `bash scripts/status.sh`.
  The helper reads the effective `/api/config` setting and refuses to alter
  `.env` when a Vaultwarden admin `config.json` overrides signups. Review
  that setting in the existing configuration manually; do not delete
  `config.json` or turn on an admin panel as a shortcut. Use
  `bash scripts/close-signups.sh` after account creation.
- **Backup failed or service is stopped:** Read the exact error and
  `sudo journalctl -u vaultwarden-backup.service --since today --no-pager`
  if the timer ran it. Check the destination mount, free space, permissions,
  Docker health, and lock contention. The script restarts a service only if it
  was running before the backup and confirms health; a power loss can still
  interrupt a backup. Preserve temporary/final archives while investigating.
- **Setup was interrupted:** Re-running `bash install.sh` on an existing
  `.env` or `vw-data/` is read-only. Run `bash scripts/status.sh`, review
  Compose/Tailscale output and these recovery steps, and do not recreate
  files or Tailscale routes blindly.
- **Installer stopped after writing `.env` or configuring Serve:** This is an
  incomplete first setup, not a reason to rerun or reset anything. Read
  `bash scripts/status.sh` and confirm the existing Serve route is exactly
  this project's `http://127.0.0.1:8080` handler. If the route belongs to
  something else, stop and ask the tailnet administrator. After HTTPS
  certificate approval/DNS is ready, start only this project's service and
  recheck both local and HTTPS health:

  ```bash
  bash -c 'source scripts/common.sh; vw_compose up -d --no-deps vaultwarden'
  curl --fail --show-error http://127.0.0.1:8080/alive
  DOMAIN="$(bash -c 'source scripts/common.sh; vw_env_read VAULTWARDEN_DOMAIN')"
  curl --fail --show-error "$DOMAIN/alive"
  ```

  If either health check fails, inspect service logs and keep registration
  closed; do not bypass TLS checks or change an unrelated Tailscale route.
- **A database migration or update failed:** Keep the verified pre-update
  archive and old data. Database schema changes can block downgrade; follow
  the coordinated restore steps in [backup-and-restore.md](backup-and-restore.md).

Do not disable the firewall, expose port 8080, open Tailscale Funnel, bypass
TLS checks, reset Tailscale Serve, delete `vw-data/`, or remove containers or
volumes as a first troubleshooting step. If unsure, stop and ask the Pi or
tailnet administrator before changing the running service.
