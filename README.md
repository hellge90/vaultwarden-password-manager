# Vaultwarden on a Raspberry Pi, kept private with Tailscale

This guide sets up **Vaultwarden**, a community-built, Bitwarden-compatible
server. It is **not** the official Bitwarden server, and Bitwarden does not
provide support for Vaultwarden. Use the official Bitwarden clients; their
ability to connect to this community server is not a promise of official
support.

The server is reachable only by devices authorized on your Tailscale network.
It uses one Vaultwarden container, stores its data under `vw-data/`, and
publishes the web app only on the Pi's loopback address. Tailscale Serve
provides HTTPS. There is no public port, router port-forward, Tailscale Funnel,
second proxy, Kubernetes, Portainer, or other app framework in this setup.

## Before you start

- A reliably powered-on Raspberry Pi running a 64-bit Raspberry Pi OS or
  compatible Debian Linux on ARM64. A USB SSD is recommended over a microSD
  card for reliability and storage life.
- Docker Engine and the Compose v2 plugin already installed and working on the
  Pi. This project does not install Docker or remove conflicting packages.
- Tailscale already installed, signed in, and running on the Pi **and** on each
  device that will use the vault. MagicDNS and HTTPS certificates must be
  enabled for the tailnet.
- Permission from the tailnet administrator to enable HTTPS certificates.
  Tailscale publishes the Pi's device name and tailnet DNS name in a public
  Certificate Transparency log. This reveals names, **not access to your
  private vault**. Rename a sensitive device before proceeding.
- A plan for protected backups, including a copy kept off the Pi and off its
  SD card/SSD.

The server commands below run in a terminal on the Pi, either locally or over
SSH. Browser and phone setup happens on those client devices. You can edit or
download this project on Windows or macOS, but its server scripts require
Linux Bash and systemd. Never run the server commands on Windows or macOS.

If you are new to a terminal: copy a whole command block, paste it into the
Pi's terminal (Ctrl+Shift+V is common; SSH terminal shortcuts vary), then press
Enter. Do not type the `$` sometimes shown in other guides. A `sudo` password
prompt does not show dots or characters while you type. Ctrl+C stops a
foreground command; do not use it while a database backup or restore is in
progress.

## 1. Install the prerequisites

Docker Engine and Compose v2 and Tailscale must already work before you run
this project. Follow the separate [Docker/Tailscale prerequisites
guide](docs/prerequisites.md) if you need to install them. The guide uses
official apt-repository instructions; it does not use `curl | sh`, uninstall
packages, upgrade the OS, or add your account to Docker's powerful `docker`
group.

On the Pi, verify the basics:

```bash
uname -m
docker --version
docker compose version
tailscale status
```

Expected: `aarch64`, Docker and Compose version information, and a Tailscale
status showing the Pi online. If Docker says permission denied, use `sudo
docker ...` for that check; the installer asks for `sudo` when needed. Access
to Docker can grant root-level power, so this guide does not add users to the
Docker group.

## 2. Get this project on the Pi

Install Git if the `git` command is missing:

```bash
sudo apt update
sudo apt install git
```

Then clone the repository and enter its folder:

```bash
git clone https://github.com/hellge90/vaultwarden-password-manager.git
cd vaultwarden-password-manager
```

Git ignores `.env`, `vw-data/`, backups, and temporary exports, but ignore
rules do not untrack files that were committed previously. Before sharing or
committing changes, check `git status --short` and make sure no private data
or export is tracked.

If the repository becomes private, GitHub may ask you to authenticate. Use
GitHub's normal SSH key or credential-manager setup; do not put a password,
personal access token, or other secret in a clone URL or command.

## 3. Run the setup

From the project folder on the Pi:

```bash
bash install.sh
```

The installer checks the OS, ARM64 architecture, systemd, Docker/Compose,
Tailscale, port 8080, and existing Serve/Funnel configuration. It creates
`.env` only if missing, creates private data directories, pulls the pinned
stable ARM64-capable Vaultwarden image, and starts the service with signups
closed. It will not overwrite an existing install or Tailscale Serve route.
If it finds an existing setup, it switches to read-only status/recovery
instructions instead of changing it.

Before it configures HTTPS, the installer asks you to confirm the Certificate
Transparency name publication described above. If Tailscale needs admin
approval, it prints the approval link supplied by Tailscale; open that link
on a device already connected to Tailscale. The installer validates the HTTPS
certificate without bypassing TLS checks. A local check does not prove that a
different client device can reach the Pi.

The initial address is printed by the installer. It will look like
`https://<this-pi>.<your-tailnet>.ts.net`; use the exact address it prints,
not this example, a Pi IP address, or `bitwarden.com`.

## 4. Create your first account, then close signups

Registration is deliberately disabled at first. In the numbered instructions
printed after setup:

1. Deliberately open registration:

   ```bash
   bash scripts/open-signups.sh
   ```

   Confirm the prompt. Any other authorized tailnet user who can reach the
   address could register while signups are open.
2. Create your first vault account in the browser. This is a normal vault
   account, **not** a Vaultwarden admin account. Choose a long, unique
   passphrase. The server cannot recover a forgotten master password.
3. Immediately close registration:

   ```bash
   bash scripts/close-signups.sh
   ```

   Do this before importing/migrating data. The script checks the effective
   registration setting, not just the text in `.env`.
4. Confirm the close script reports that registration is disabled; then sign
   in again and test the account.
5. Enable two-factor authentication in the account, and keep its recovery code
   somewhere safe and offline, outside the vault.

This setup does not configure SMTP/email. Do not rely on email-based account
recovery or invitations.

## 5. Install clients and test sync

Install the official [Bitwarden browser extension](https://bitwarden.com/download/#downloads-web-browser)
for Chrome, Edge, or Brave, or the [official mobile app](https://bitwarden.com/download/).
The Pi and client must both be connected to Tailscale when the client connects
or syncs.

In the client login screen, select **Logging in on** (or the equivalent server
selector), choose **Self-hosted**, enter the **exact HTTPS URL printed by the
installer**, and save it. In the mobile app, use the same self-hosted server
URL before signing in. Never enter the Pi's HTTP address, raw IP, or
`bitwarden.com` for this server.

For a first test, log in, save a dummy item, trigger a manual sync, and check
that the same dummy item appears on another Tailscale-connected client.
Background push notifications are not configured, so sync is not necessarily
instant. A client may show cached vault data while offline; that does not mean
it has synced.

## 6. Migrate existing entries carefully

Use the current official [Bitwarden export
instructions](https://bitwarden.com/help/export-your-data/) in the old
password manager and the official [Bitwarden import
instructions](https://bitwarden.com/help/import-data/) in your new client.
The current web-app menus are **Tools → Export** and **Tools → Import**; names
can vary slightly by client version. Export/import one browser at a time and
review the imported item count and contents for duplicates before removing
anything from the old manager.

A CSV export is **plain text**: anyone who can read it can read the passwords.
Do not email it, share it, upload it to GitHub, or store it in a synced folder.
Keep the export only on a device you control; after checking the migration,
delete the temporary export and empty that device's trash/recycle bin. This
reduces exposure but is not a promise of forensic erasure. Keep the original
manager until the new vault and a backup have both been checked.

## Backups, updates, and help

- [Back up and restore](docs/backup-and-restore.md) explains manual backups,
  an optional systemd timer, and a safe isolated restore test. A backup on the
  same SD card/SSD does not protect against that device failing.
- [Troubleshooting](docs/troubleshooting.md) covers common terminal, Docker,
  port, Tailscale, HTTPS, account, and backup problems. Do not delete
  `vw-data/`, disable a firewall, bypass a certificate warning, or reset Serve
  as a first troubleshooting step.
- To check an existing setup without changing it:

  ```bash
  bash scripts/status.sh
  ```

- Updates are deliberate: choose a stable Vaultwarden version and follow
  [the update steps](docs/backup-and-restore.md#updating).

## Before you call setup finished

- [ ] Open the exact HTTPS URL from a **different, Tailscale-connected
  device** and confirm the browser accepts its certificate.
- [ ] Create and test the first account.
- [ ] Verify registration is closed using `bash scripts/close-signups.sh`.
- [ ] Save a dummy item and manually sync it on a second client.
- [ ] Enable 2FA and store the recovery code safely outside the vault.
- [ ] Create and verify the first backup archive.
- [ ] Copy a backup to protected storage away from the Pi.
- [ ] Complete an isolated restore test before trusting the only copy.

## Official references

- [Vaultwarden project](https://github.com/dani-garcia/vaultwarden),
  [wiki](https://github.com/dani-garcia/vaultwarden/wiki),
  [configuration template](https://github.com/dani-garcia/vaultwarden/blob/main/.env.template),
  [stable releases](https://github.com/dani-garcia/vaultwarden/releases),
  and [backup guidance](https://github.com/dani-garcia/vaultwarden/wiki/Backing-up-your-vault).
- [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve),
  [Funnel](https://tailscale.com/docs/reference/tailscale-cli/funnel),
  [HTTPS certificates and public Certificate Transparency logs](https://tailscale.com/docs/how-to/set-up-https-certificates),
  and [Tailscale CLI reference](https://tailscale.com/docs/reference/tailscale-cli).
- Bitwarden [downloads](https://bitwarden.com/download/),
  [export](https://bitwarden.com/help/export-your-data/),
  and [import](https://bitwarden.com/help/import-data/).
- Docker's official [Engine install instructions for Debian](https://docs.docker.com/engine/install/debian/).
