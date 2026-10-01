# Pi prerequisites: Docker Engine, Compose, and Tailscale

Complete this guide on the Raspberry Pi, not on your Windows/macOS browser
computer. The Vaultwarden installer expects a 64-bit Raspberry Pi OS or
Debian-family Linux system, a working Docker daemon with the Compose v2
plugin, and Tailscale already installed and signed in on the Pi.

This project does not remove packages, upgrade Debian, run a convenience
installer, install Kubernetes/Portainer, or add your user to the Docker group.
If Docker is already installed, do not replace it just because it came from a
different source. Resolve any Docker/Compose conflict with the administrator
of that Pi first.

## Docker Engine from Docker's official apt repository

Docker's official Debian documentation currently lists Debian 12 (Bookworm)
and Debian 13 (Trixie), with ARM64 support. Raspberry Pi OS releases and
derivatives can differ; check `/etc/os-release` and Docker's current
[Debian install guide](https://docs.docker.com/engine/install/debian/) before
copying these commands. The commands below configure Docker's signed apt
repository; they do not install or remove any packages.

On the Pi terminal:

```bash
cat /etc/os-release
dpkg --print-architecture
sudo apt update
sudo apt install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

Add the official Docker source. This reads the Debian codename from the local
OS release file and architecture from `dpkg`:

```bash
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt update
```

If the Pi's release is not listed by Docker's current guide, stop and follow
the vendor instructions for a supported release; do not guess a codename.
Review available packages before installing:

```bash
apt list --all-versions docker-ce
```

If Docker is not already installed and the package list matches this Pi,
install the engine, CLI, container runtime, build plugin, and Compose v2
plugin:

```bash
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

If apt reports conflicting packages, stop. Do not remove or replace packages
automatically; ask the Pi administrator to identify the existing installation
and choose a migration plan. The command above installs the current stable
packages from Docker's official repository; it does not upgrade the operating
system.

Check that the daemon and Compose v2 work:

```bash
sudo systemctl status docker --no-pager
sudo docker info
sudo docker compose version
```

Expected: Docker is active, `docker info` prints server details, and Compose
reports version 2. A non-root `docker` permission error is expected unless
your administrator deliberately configured another access method. The
`docker` group can grant root-level power; this setup intentionally does not
add your user to it. The Vaultwarden scripts request `sudo` only where Docker
or Tailscale needs administrator permission.

Docker warns that published container ports can bypass some host firewall
rules. This project publishes only `127.0.0.1:8080`, not a LAN or public
interface; do not add a port-forward or change the binding.

## Tailscale

Tailscale is installed and managed separately on the host. Follow the
[official Linux install guide](https://tailscale.com/kb/1031/install-linux/)
and [Tailscale HTTPS setup guide](https://tailscale.com/docs/how-to/set-up-https-certificates)
if needed. Sign in the Pi and client devices to the intended tailnet, enable
MagicDNS and HTTPS certificates in its admin console, and verify:

```bash
tailscale status
tailscale status --json
```

This project does not install, sign in, reconfigure, reset, or expose
Tailscale. It refuses to take over existing Serve routes or Funnel
configuration.
