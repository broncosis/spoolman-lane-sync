#!/usr/bin/env bash
# Spoolman Lane Sync — one-line installer
# Usage:  curl -fsSL https://raw.githubusercontent.com/broncosis/spoolman-lane-sync/main/install.sh | bash
set -euo pipefail

REPO_URL="https://github.com/broncosis/spoolman-lane-sync.git"
INSTALL_DIR="${HOME}/spoolman-lane-sync"
SERVICE_NAME="spoolman-lane-sync"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║      Spoolman Lane Sync  —  installer     ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── Git clone / update ────────────────────────────────────────────────────────
if [[ -d "${INSTALL_DIR}/.git" ]]; then
    echo "Updating existing installation in ${INSTALL_DIR}…"
    git -C "${INSTALL_DIR}" pull --ff-only
else
    echo "Cloning into ${INSTALL_DIR}…"
    git clone "${REPO_URL}" "${INSTALL_DIR}"
fi
echo ""

# ── Python ────────────────────────────────────────────────────────────────────
PYTHON="$(command -v python3 || true)"
if [[ -z "$PYTHON" ]]; then
    echo "ERROR: python3 not found. Install it with: sudo apt install python3"
    exit 1
fi
echo "Python: $("$PYTHON" --version)"

if ! "$PYTHON" -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" 2>/dev/null; then
    echo "ERROR: Python 3.10+ is required."
    exit 1
fi

# ── aiohttp ───────────────────────────────────────────────────────────────────
if "$PYTHON" -c "import aiohttp" 2>/dev/null; then
    echo "aiohttp: already installed"
else
    echo "Installing aiohttp…"
    "$PYTHON" -m pip install --user aiohttp
fi
echo ""

# ── Config (.env) ─────────────────────────────────────────────────────────────
ENV_FILE="${INSTALL_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
    echo ".env: already exists — skipping (delete it to reconfigure)"
    echo ""
else
    # Prompt interactively when running in a terminal; use defaults when piped
    if [[ -t 0 ]]; then
        echo "Configure connection URLs (press Enter to accept default):"
        echo ""

        read -r -p "  Moonraker URL  [http://localhost:7125]: " MOONRAKER_URL </dev/tty
        MOONRAKER_URL="${MOONRAKER_URL:-http://localhost:7125}"

        read -r -p "  Spoolman URL   [http://localhost:7912]: " SPOOLMAN_URL </dev/tty
        SPOOLMAN_URL="${SPOOLMAN_URL:-http://localhost:7912}"

        read -r -p "  Moonraker API key (leave blank if auth is off): " MR_API_KEY </dev/tty
        MR_API_KEY="${MR_API_KEY:-}"

        echo ""
    else
        echo "Non-interactive install — writing defaults to .env."
        echo "Edit ${ENV_FILE} to set your Moonraker and Spoolman URLs."
        echo ""
        MOONRAKER_URL="http://localhost:7125"
        SPOOLMAN_URL="http://localhost:7912"
        MR_API_KEY=""
    fi

    cat > "$ENV_FILE" <<ENVEOF
# Spoolman Lane Sync — configuration
# Edit these values to match your setup, then: sudo systemctl restart ${SERVICE_NAME}

MOONRAKER_URL=${MOONRAKER_URL}
SPOOLMAN_URL=${SPOOLMAN_URL}
MOONRAKER_API_KEY=${MR_API_KEY}
LOG_LEVEL=INFO
ENVEOF

    echo "Created: ${ENV_FILE}"
    echo ""
fi

# ── systemd unit ──────────────────────────────────────────────────────────────
CURRENT_USER="$(whoami)"
SCRIPT="${INSTALL_DIR}/spoolman_lane_sync.py"

echo "Writing ${SERVICE_FILE}  (sudo required)…"
if ! sudo -v 2>/dev/null; then
    echo "ERROR: sudo access is required to install the systemd service."
    echo "Run the script directly (not piped) so sudo can prompt for a password:"
    echo ""
    echo "  bash <(curl -fsSL https://raw.githubusercontent.com/broncosis/spoolman-lane-sync/main/install.sh)"
    exit 1
fi

sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Spoolman to Moonraker lane_data sync
Documentation=https://github.com/broncosis/spoolman-lane-sync
After=network-online.target moonraker.service
Wants=network-online.target

[Service]
Type=simple
User=${CURRENT_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${PYTHON} ${SCRIPT}
Restart=always
RestartSec=10
EnvironmentFile=-${ENV_FILE}

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}"
echo ""

# ── Done ──────────────────────────────────────────────────────────────────────
echo "✅  Installed and enabled: ${SERVICE_NAME}"
echo ""
echo "Start the service:"
echo "  sudo systemctl start ${SERVICE_NAME}"
echo ""
echo "Watch logs:"
echo "  journalctl -u ${SERVICE_NAME} -f"
echo ""
echo "Verify lane_data after starting:"
echo "  curl -s 'http://localhost:7125/server/database/item?namespace=lane_data&key=tools' | python3 -m json.tool"
echo ""
echo "Config file:  ${ENV_FILE}"
echo ""
