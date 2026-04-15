#!/usr/bin/env bash
# entrypoint.sh – start CUPS + AirSane for AirPrint/AirScan relay
set -euo pipefail

# ── Validate required environment variables ──────────────────────────────────
: "${SCANNER_IP:?SCANNER_IP is required}"
: "${SCANNER_NAME:?SCANNER_NAME is required}"
: "${SCANNER_MODEL:?SCANNER_MODEL is required}"
: "${CUPS_ADMIN_USER:?CUPS_ADMIN_USER is required}"
: "${CUPS_ADMIN_PASSWORD:?CUPS_ADMIN_PASSWORD is required}"
: "${PRINTER_NAME:?PRINTER_NAME is required}"
: "${PRINTER_URI:?PRINTER_URI is required}"
: "${PRINTER_MODEL:?PRINTER_MODEL is required}"
: "${AIRSANE_PORT:?AIRSANE_PORT is required}"

# AirSane runtime toggles. Defaults are conservative because some SANE backends
# crash when hotplug/mDNS paths are enabled in minimal container environments.
AIRSANE_DEBUG="${AIRSANE_DEBUG:-true}"
AIRSANE_ACCESS_LOG="${AIRSANE_ACCESS_LOG:--}"
AIRSANE_MDNS_ANNOUNCE="${AIRSANE_MDNS_ANNOUNCE:-false}"
AIRSANE_HOTPLUG="${AIRSANE_HOTPLUG:-false}"
AIRSANE_NETWORK_HOTPLUG="${AIRSANE_NETWORK_HOTPLUG:-false}"
AIRSANE_EXTRA_ARGS="${AIRSANE_EXTRA_ARGS:-}"

# ── 1. Configure brscan4 scanner backend ─────────────────────────────────────
echo "[1/7] Registering scanner with brscan4 (${SCANNER_NAME} / ${SCANNER_MODEL} @ ${SCANNER_IP})..."
# brsaneconfig4 exits non-zero if the entry already exists (container restart)
brsaneconfig4 -a \
    name="${SCANNER_NAME}" \
    model="${SCANNER_MODEL}" \
    ip="${SCANNER_IP}" || true

# ── 2. Create CUPS admin user ─────────────────────────────────────────────────
echo "[2/7] Configuring CUPS admin user '${CUPS_ADMIN_USER}'..."
if ! id "${CUPS_ADMIN_USER}" &>/dev/null; then
    useradd -r -s /usr/sbin/nologin "${CUPS_ADMIN_USER}"
fi
usermod -aG lpadmin "${CUPS_ADMIN_USER}"
echo "${CUPS_ADMIN_USER}:${CUPS_ADMIN_PASSWORD}" | chpasswd

# ── 3. Configure CUPS for network access ─────────────────────────────────────
echo "[3/7] Patching CUPS configuration..."

# Listen on all interfaces instead of loopback only
sed -i 's|^Listen localhost:631|Listen 0.0.0.0:631|' /etc/cups/cupsd.conf

# Accept any ServerName/ServerAlias so the CUPS web UI is reachable
grep -qF 'ServerAlias *' /etc/cups/cupsd.conf \
    || sed -i '/^ServerName/a ServerAlias *' /etc/cups/cupsd.conf

# Append permissive Location blocks; CUPS uses the last matching block,
# so these override the restrictive defaults shipped in the package.
cat >> /etc/cups/cupsd.conf <<'EOF'

# Allow remote access – appended by entrypoint.sh
<Location />
  Order allow,deny
  Allow all
</Location>
<Location /admin>
  Order allow,deny
  Allow all
</Location>
<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow all
</Location>
EOF

# ── 4. Start CUPS ─────────────────────────────────────────────────────────────
echo "[4/7] Starting CUPS..."
/usr/sbin/cupsd -f &
CUPS_PID=$!

# ── 5. Wait for CUPS to become ready ─────────────────────────────────────────
echo "[5/7] Waiting for CUPS to be ready..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:631/ > /dev/null 2>&1; then
        echo "        CUPS is ready (${i}s)."
        break
    fi
    if [ "${i}" -eq 30 ]; then
        echo "ERROR: CUPS did not become ready within 30 s." >&2
        exit 1
    fi
    sleep 1
done

# ── 6. Configure CUPS policies and add printer ────────────────────────────────
echo "[6/7] Configuring CUPS policies and registering printer..."

# The CUPS admin socket can become ready slightly after the HTTP health check
# passes. _cups_retry wraps a command in a retry loop, checking the exit code
# directly — no fragile output parsing.
_cups_retry() {
    local label="$1"; shift
    local i
    for i in $(seq 1 10); do
        if "$@"; then
            echo "        ${label} OK."
            return 0
        fi
        [ "${i}" -eq 10 ] \
            && { echo "ERROR: ${label} failed after 10 attempts." >&2; return 1; }
        echo "        ${label} not ready, retrying in 2s... (${i}/10)"
        sleep 2
    done
}

_cups_retry cupsctl   cupsctl   -h localhost:631 --share-printers --remote-admin --remote-any
_cups_retry lpadmin   lpadmin   -h localhost:631 -p "${PRINTER_NAME}" -E -v "${PRINTER_URI}" -m "${PRINTER_MODEL}"
_cups_retry cupsenable cupsenable -h localhost:631 "${PRINTER_NAME}"
_cups_retry cupsaccept cupsaccept -h localhost:631 "${PRINTER_NAME}"

echo "        Printer '${PRINTER_NAME}' registered (${PRINTER_URI})."

# ── 7. Start AirSane ─────────────────────────────────────────────────────────
echo "[7/7] Starting AirSane on port ${AIRSANE_PORT}..."

echo "        Probing SANE devices before starting AirSane..."
if scanimage -L > /tmp/scanimage.log 2>&1; then
    sed 's/^/        /' /tmp/scanimage.log
else
    echo "        WARNING: scanimage probe failed (continuing):"
    sed 's/^/        /' /tmp/scanimage.log || true
fi

_start_airsane() {
    local cmd=(
        airsaned
        "--listen-port=${AIRSANE_PORT}"
        "--debug=${AIRSANE_DEBUG}"
        "--access-log=${AIRSANE_ACCESS_LOG}"
        "--mdns-announce=${AIRSANE_MDNS_ANNOUNCE}"
        "--hotplug=${AIRSANE_HOTPLUG}"
        "--network-hotplug=${AIRSANE_NETWORK_HOTPLUG}"
    )

    if [ -n "${AIRSANE_EXTRA_ARGS}" ]; then
        # Intentionally split user-provided args on whitespace.
        # shellcheck disable=SC2206
        local extra=( ${AIRSANE_EXTRA_ARGS} )
        cmd+=("${extra[@]}")
    fi

    echo "        AirSane command: ${cmd[*]}"
    "${cmd[@]}" &
    AIRSANE_PID=$!
}

_start_airsane

# Detect fast-crash startup failures early to produce a useful error message.
sleep 2
if ! kill -0 "${AIRSANE_PID}" 2>/dev/null; then
    wait "${AIRSANE_PID}" 2>/dev/null || true
    echo "ERROR: AirSane exited during startup (possible backend crash)." >&2
    echo "       If this started after upgrading AirSane, try AIRSANE_REF=v0.4.9 at build time." >&2
    echo "       Also verify SCANNER_MODEL and check scanimage output above." >&2
    exit 1
fi

echo "════════════════════════════════════════"
echo " CUPS:     http://0.0.0.0:631"
echo " AirSane:  http://0.0.0.0:${AIRSANE_PORT}"
echo "════════════════════════════════════════"

# ── Monitor and forward signals ───────────────────────────────────────────────
_shutdown() {
    echo "Shutting down..."
    kill "${CUPS_PID}" "${AIRSANE_PID}" 2>/dev/null || true
    wait "${CUPS_PID}" "${AIRSANE_PID}" 2>/dev/null || true
    exit 0
}
trap _shutdown TERM INT

# Exit the container as soon as either main process dies
while kill -0 "${CUPS_PID}" 2>/dev/null \
   && kill -0 "${AIRSANE_PID}" 2>/dev/null; do
    sleep 5
done

echo "A service exited unexpectedly – stopping container."
_shutdown
