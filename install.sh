#!/usr/bin/env bash
# install.sh — install spoolman-lane-sync as a systemd service
set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="spoolman-lane-sync"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT="${INSTALL_DIR}/spoolman_lane_sync.py"
CURRENT_USER="$(whoami)"

echo "=== Spoolman Lane Sync installer ==="
echo "Install dir: ${INSTALL_DIR}"
echo "User:        ${CURRENT_USER}"
echo ""

# ── Python ────────────────────────────────────────────────────────────────────
PYTHON="$(command -v python3 || true)"
if [[ -z "$PYTHON" ]]; then
    echo "ERROR: python3 not found. Install it with: sudo apt install python3"
    exit 1
fi

PY_VERSION="$("$PYTHON" -c 'import sys; print(sys.version_info[:2])')"
echo "Python: $PYTHON  ($("$PYTHON" --version))"

if ! "$PYTHON" -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
    echo "ERROR: Python 3.10+ required."
    exit 1
fi

# ── aiohttp ───────────────────────────────────────────────────────────────────
if "$PYTHON" -c "import aiohttp" 2>/dev/null; then
    echo "aiohttp: already installed"
else
    echo "Installing aiohttp…"
    "$PYTHON" -m pip install --user aiohttp
fi

# ── .env ─────────────────────────────────────────────────────────────────────
if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
    cp "${INSTALL_DIR}/.env.example" "${INSTALL_DIR}/.env"
    echo ""
    echo "⚠️  Created .env from template. Edit it before starting the service:"
    echo "   nano ${INSTALL_DIR}/.env"
    echo ""
else
    echo ".env: already exists (not overwritten)"
fi

# ── systemd unit ──────────────────────────────────────────────────────────────
echo "Writing ${SERVICE_FILE}…"

sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Spoolman to Moonraker lane_data sync
Documentation=https://github.com/Broncosis/spoolman-lane-sync
After=network-online.target moonraker.service spoolman.service
Wants=network-online.target moonraker.service spoolman.service

[Service]
Type=simple
User=${CURRENT_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${PYTHON} ${SCRIPT}
Restart=always
RestartSec=10
# Load config from .env (key=value, no 'export')
EnvironmentFile=-${INSTALL_DIR}/.env

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}"

echo ""
echo "✅ Installed and enabled: ${SERVICE_NAME}"
echo ""
echo "Next steps:"
echo "  1. Edit config:   nano ${INSTALL_DIR}/.env"
echo "  2. Start service: sudo systemctl start ${SERVICE_NAME}"
echo "  3. Watch logs:    journalctl -u ${SERVICE_NAME} -f"
echo ""
echo "Verify lane_data after starting:"
echo "  curl -s 'http://localhost:7125/server/database/item?namespace=lane_data&key=tools' | python3 -m json.tool"
