#!/usr/bin/env bash
# Spoolman Lane Sync — one-line installer
# Usage:  bash <(curl -fsSL https://raw.githubusercontent.com/broncosis/spoolman-lane-sync/main/install.sh)
set -euo pipefail

REPO_URL="https://github.com/broncosis/spoolman-lane-sync.git"
INSTALL_DIR="${HOME}/spoolman-lane-sync"
VENV_DIR="${INSTALL_DIR}/venv"
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

# ── Virtual environment ───────────────────────────────────────────────────────
if [[ -f "${VENV_DIR}/bin/python" ]]; then
    echo "venv: already exists — skipping"
else
    echo "Creating virtual environment in ${VENV_DIR}…"
    "$PYTHON" -m venv "${VENV_DIR}"
fi
VENV_PYTHON="${VENV_DIR}/bin/python"

echo "Installing aiohttp…"
"${VENV_PYTHON}" -m pip install --quiet --upgrade aiohttp
echo "aiohttp: installed"
echo ""

# ── Auto-detect Spoolman URL from moonraker.conf ──────────────────────────────
_detect_spoolman_url() {
    local candidates=(
        "${HOME}/printer_data/config/moonraker.conf"
        "${HOME}/klipper_config/moonraker.conf"
        "/etc/moonraker.conf"
    )
    local in_section=0
    for conf in "${candidates[@]}"; do
        [[ -f "$conf" ]] || continue
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[spoolman\] ]]; then
                in_section=1; continue
            fi
            if [[ $in_section -eq 1 ]]; then
                [[ "$line" =~ ^\[ ]] && break
                if [[ "$line" =~ ^server[[:space:]]*[:=][[:space:]]*(.+) ]]; then
                    echo "${BASH_REMATCH[1]}" | xargs
                    return 0
                fi
            fi
        done < "$conf"
        in_section=0
    done
}

DETECTED_SPOOLMAN="$(_detect_spoolman_url || true)"

# ── Config (.env) ─────────────────────────────────────────────────────────────
ENV_FILE="${INSTALL_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
    echo ".env: already exists — skipping (delete it to reconfigure)"
    echo ""
else
    MOONRAKER_URL="http://localhost:7125"
    SPOOLMAN_URL="${DETECTED_SPOOLMAN:-http://localhost:7912}"
    MR_API_KEY=""

    if [[ -n "$DETECTED_SPOOLMAN" ]]; then
        echo "Detected Spoolman URL from moonraker.conf: ${DETECTED_SPOOLMAN}"
    fi

    if [[ -t 0 ]]; then
        echo "Configure connection URLs (press Enter to accept):"
        echo ""

        read -r -p "  Moonraker URL  [${MOONRAKER_URL}]: " _in </dev/tty
        MOONRAKER_URL="${_in:-${MOONRAKER_URL}}"

        read -r -p "  Spoolman URL   [${SPOOLMAN_URL}]: " _in </dev/tty
        SPOOLMAN_URL="${_in:-${SPOOLMAN_URL}}"

        read -r -p "  Moonraker API key (leave blank if auth is off): " MR_API_KEY </dev/tty
        MR_API_KEY="${MR_API_KEY:-}"

        echo ""
    else
        echo "Non-interactive install — using detected/default URLs."
        echo "Edit ${ENV_FILE} to adjust if needed."
        echo ""
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
    echo "Run with:"
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
ExecStart=${VENV_PYTHON} ${SCRIPT}
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
