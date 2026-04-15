# truenas-airprint-relay

A Docker image that turns a Brother network printer/scanner into an **AirPrint** and **AirScan** device — built for TrueNAS Scale but deployable anywhere.

| Service | Purpose |
|---|---|
| CUPS + brlaser | Receives IPP print jobs and forwards them to the printer via raw socket |
| brscan4 | Brother's official SANE backend, connects to the scanner over the network |
| AirSane | Compiles from source; serves eSCL so iPhones and Macs can scan wirelessly |

No Avahi daemon runs inside the container. Instead, the container mounts the host's D-Bus socket and lets TrueNAS's existing Avahi daemon handle all mDNS advertisement.

The image is built for `linux/amd64` and published to GitHub Container Registry on every push to `main` that touches `configs/airprint/`.

---

## Repository layout

```
.github/workflows/
  build-airprint.yml      GitHub Actions – build and push to ghcr.io

configs/airprint/
  Dockerfile              Multi-stage: compile AirSane, then debian:bookworm-slim runtime
  entrypoint.sh           Ordered startup script (brscan4 → CUPS → printer → AirSane)
  docker-compose.yml      Generic reference compose file
```

---

## Prerequisites

- A Brother printer/scanner reachable on the local network
- TrueNAS Scale **Electric Eel (24.10)** or later (Docker Compose custom apps)
- A GitHub account to host the container image on `ghcr.io`
- Target runtime architecture: **linux/amd64** (required by Brother brscan4)

Note for Apple Silicon development hosts: local native builds are not representative,
because brscan4 is amd64-only. Build/publish for amd64 and validate on an amd64 runtime
(e.g. TrueNAS Scale).

---

## One-time GitHub setup

### 1. Set the `BRSCAN4_URL` repository variable

The workflow downloads the brscan4 `.deb` at build time. Supply the URL as a repository variable so it is never hard-coded in the image.

**Settings → Secrets and variables → Actions → Variables → New repository variable**

| Name | Value |
|---|---|
| `BRSCAN4_URL` | `https://download.brother.com/welcome/dlf105200/brscan4-0.4.11-1.amd64.deb` |

Check [Brother's download page](https://support.brother.com) for a newer version before setting this.

### 2. Push to `main` to trigger the first build

```bash
git push origin main
```

The workflow runs automatically when anything under `configs/airprint/` changes. You can also trigger it manually from **Actions → Build and push AirPrint relay image → Run workflow**, which also lets you override the brscan4 URL for a one-off rebuild.

### 3. Make the published package public

After the first successful run GitHub creates the package as private by default.

**Your profile → Packages → `truenas-airprint-relay` → Package settings → Change visibility → Public**

This allows TrueNAS to pull the image without credentials.

---

## Deploying on TrueNAS Scale

### 1. Open the Custom App installer

**Apps → Discover Apps → Custom App → Install via Compose**

### 2. Paste and fill in the compose manifest

Copy the block below, replace `GITHUB_OWNER` with your GitHub username, set `CUPS_ADMIN_PASSWORD`, confirm the IPs match your network, then paste it into the TrueNAS compose editor.

```yaml
name: airprint-relay

services:
  airprint-relay:
    image: ghcr.io/GITHUB_OWNER/truenas-airprint-relay:latest
    restart: unless-stopped

    ports:
      - "631:631"    # CUPS / IPP
      - "8090:8090"  # AirSane eSCL

    volumes:
      - type: bind
        source: /run/dbus/system_bus_socket
        target: /run/dbus/system_bus_socket
      # Optional: persist print spool across restarts.
      # Create the dataset first: zfs create tank/apps/airprint-relay/cups-spool
      #- type: bind
      #  source: /mnt/POOL/apps/airprint-relay/cups-spool
      #  target: /var/spool/cups

    environment:
      CUPS_ADMIN_USER: "admin"
      CUPS_ADMIN_PASSWORD: "CHANGE_ME"
      PRINTER_NAME: "Brother-MFC-1910W"
      PRINTER_URI: "socket://192.168.1.81:9100"
      PRINTER_MODEL: "drv:///brlaser.drv/br1910w.ppd"
      SCANNER_IP: "192.168.1.81"
      SCANNER_NAME: "Brother"
      SCANNER_MODEL: "MFC-1910W"
      AIRSANE_PORT: "8090"
      DBUS_SYSTEM_BUS_ADDRESS: "unix:path=/run/dbus/system_bus_socket"
      AIRSANE_DEBUG: "true"
      AIRSANE_ACCESS_LOG: "-"
      AIRSANE_MDNS_ANNOUNCE: "false"
      AIRSANE_HOTPLUG: "false"
      AIRSANE_NETWORK_HOTPLUG: "false"

    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:631/"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
```

See the [Configuration reference](#configuration-reference) below for a description of every variable.

### 3. Verify the image pulls

```bash
docker pull ghcr.io/YOUR_USERNAME/truenas-airprint-relay:latest
```

---

## Configuration reference

All runtime behaviour is controlled via environment variables. Nothing is hard-coded in the image.

| Variable | Required | Description |
|---|---|---|
| `CUPS_ADMIN_USER` | yes | Username for the CUPS web UI admin account |
| `CUPS_ADMIN_PASSWORD` | yes | Password for the CUPS admin account |
| `PRINTER_NAME` | yes | Queue name shown in print dialogs (no spaces) |
| `PRINTER_URI` | yes | Device URI, e.g. `socket://192.168.1.81:9100` |
| `PRINTER_MODEL` | yes | brlaser model URI, format: `drv:///brlaser.drv/<pcfilename>.ppd` (see below) |
| `SCANNER_IP` | yes | IP address of the scanner on the network |
| `SCANNER_NAME` | yes | Friendly name registered with brscan4 |
| `SCANNER_MODEL` | yes | Model string recognised by brscan4 (see below) |
| `AIRSANE_PORT` | yes | Port AirSane listens on; must match the port mapping |
| `AIRSANE_DEBUG` | no | AirSane debug logging (`true`/`false`, default `true`) |
| `AIRSANE_ACCESS_LOG` | no | AirSane HTTP access log destination (default `-` for stdout) |
| `AIRSANE_MDNS_ANNOUNCE` | no | Enable AirSane mDNS announcements (`true`/`false`, default `false`) |
| `AIRSANE_HOTPLUG` | no | Enable scanner hotplug reload (`true`/`false`, default `false`) |
| `AIRSANE_NETWORK_HOTPLUG` | no | Enable network-change reload (`true`/`false`, default `false`) |
| `AIRSANE_EXTRA_ARGS` | no | Extra raw CLI args appended to `airsaned` |
| `DBUS_SYSTEM_BUS_ADDRESS` | recommended | Override D-Bus socket path; set to `unix:path=/run/dbus/system_bus_socket` |

### Finding the correct `PRINTER_MODEL` URI

`printer-driver-brlaser` generates PPDs dynamically from `/usr/share/cups/drv/brlaser.drv`. To find the `PCFileName` for your model:

```bash
docker run --rm --entrypoint bash ghcr.io/GITHUB_OWNER/truenas-airprint-relay:latest \
  -c "grep -i 'PCFileName\|ModelName' /usr/share/cups/drv/brlaser.drv"
```

Take the `PCFileName` value (e.g. `br1910w.ppd`) and set:

```
PRINTER_MODEL=drv:///brlaser.drv/br1910w.ppd
```

### Finding a valid `SCANNER_MODEL` string

brscan4 ships with a list of supported model identifiers. To query it:

```bash
docker exec -it <container_name> brsaneconfig4 -q
```

---

## Build arguments

These are set at image build time, not at runtime.

| Argument | Required | Description |
|---|---|---|
| `BRSCAN4_URL` | yes | URL of the brscan4 `.deb` to download during build |
| `AIRSANE_REPO` | no | Git remote for AirSane (default: upstream GitHub) |
| `AIRSANE_REF` | no | Tag or branch to build AirSane from (default: `v0.4.9`) |

---

## Ports

| Port | Protocol | Service |
|---|---|---|
| `631` | TCP | CUPS / IPP — printing |
| `8090` | TCP | AirSane eSCL — scanning (iOS Continuity Camera, macOS Image Capture) |

---

## How mDNS advertisement works

The container has no Avahi daemon. At startup, AirSane and CUPS both use `libavahi-client` to register their mDNS/DNS-SD records. They reach the host's Avahi daemon through the D-Bus socket mounted at `/run/dbus/system_bus_socket`, so advertisements appear on the LAN without running a second Avahi instance.

**Required volume mount:**
```yaml
- /run/dbus/system_bus_socket:/run/dbus/system_bus_socket
```
