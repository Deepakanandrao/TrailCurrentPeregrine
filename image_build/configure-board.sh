#!/usr/bin/env bash
# ============================================================================
# TrailCurrent Peregrine — Post-Flash Board Configuration
#
# Configures board-specific settings (MQTT, static IP) after flashing
# the golden image. Connects via SSH to the board.
#
# Usage:
#   ./configure-board.sh <hostname-or-ip>
#   ./configure-board.sh peregrine.local
# ============================================================================

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <hostname-or-ip>"
    echo "  e.g. $0 peregrine.local"
    exit 1
fi

TARGET="$1"
if [[ "$TARGET" != *@* ]]; then
    TARGET="root@${TARGET}"
fi

REMOTE_HOME="/home/assistant"

echo ""
echo "============================================"
echo "  TrailCurrent Peregrine — Board Setup"
echo "============================================"
echo ""

# Test connectivity
echo "Connecting to ${TARGET}..."
ssh -o ConnectTimeout=5 "$TARGET" "hostname" >/dev/null 2>&1 || {
    echo "ERROR: Cannot reach ${TARGET}"
    echo "Make sure the board is powered on and connected via Ethernet."
    exit 1
}
echo "Connected."
echo ""

# ── MQTT Configuration ───────────────────────────────────────────────────

echo "── MQTT Configuration ──"
echo ""

read -rp "MQTT broker address (e.g. 192.168.1.100): " MQTT_BROKER
if [[ -z "$MQTT_BROKER" ]]; then
    echo "Skipping MQTT configuration."
else
    read -rp "MQTT port [8883]: " MQTT_PORT
    MQTT_PORT="${MQTT_PORT:-8883}"

    read -rp "Use TLS? [y/N]: " MQTT_TLS
    MQTT_TLS="${MQTT_TLS:-n}"

    read -rp "MQTT username (blank for none): " MQTT_USER
    read -rsp "MQTT password (blank for none): " MQTT_PASS
    echo ""

    # Build the env file content
    ENV_CONTENT="# Voice assistant environment config
# Edit with: nano ~/assistant.env
# Then restart: sudo systemctl restart voice-assistant

# MQTT
MQTT_BROKER=${MQTT_BROKER}
MQTT_PORT=${MQTT_PORT}"

    if [[ "${MQTT_TLS,,}" == "y" || "${MQTT_TLS,,}" == "yes" ]]; then
        ENV_CONTENT="${ENV_CONTENT}
MQTT_USE_TLS=true
MQTT_CA_CERT=/home/assistant/ca.pem"
    fi

    if [[ -n "$MQTT_USER" ]]; then
        ENV_CONTENT="${ENV_CONTENT}
MQTT_USERNAME=${MQTT_USER}"
    fi
    if [[ -n "$MQTT_PASS" ]]; then
        ENV_CONTENT="${ENV_CONTENT}
MQTT_PASSWORD=${MQTT_PASS}"
    fi

    ENV_CONTENT="${ENV_CONTENT}

# Audio tuning
#WAKE_THRESHOLD=0.5
#SILENCE_THRESHOLD=500
#SILENCE_DURATION=1.5"

    # Write to the board
    ssh "$TARGET" "cat > ${REMOTE_HOME}/assistant.env << 'ENVEOF'
${ENV_CONTENT}
ENVEOF
chown assistant:assistant ${REMOTE_HOME}/assistant.env"

    echo "MQTT configured: ${MQTT_BROKER}:${MQTT_PORT}"

    # Copy TLS certificate if needed
    if [[ "${MQTT_TLS,,}" == "y" || "${MQTT_TLS,,}" == "yes" ]]; then
        echo ""
        read -rp "Path to CA certificate (or blank to skip): " CA_PATH
        if [[ -n "$CA_PATH" && -f "$CA_PATH" ]]; then
            scp "$CA_PATH" "${TARGET}:${REMOTE_HOME}/ca.pem"
            ssh "$TARGET" "chown assistant:assistant ${REMOTE_HOME}/ca.pem"
            echo "TLS certificate installed."
        else
            echo "No certificate copied. Copy it manually:"
            echo "  scp ca.pem ${TARGET}:${REMOTE_HOME}/ca.pem"
        fi
    fi
fi

echo ""

# ── Static IP (optional) ────────────────────────────────────────────────

echo "── Network Configuration ──"
echo ""
read -rp "Set a static IP? [y/N]: " SET_STATIC
if [[ "${SET_STATIC,,}" == "y" || "${SET_STATIC,,}" == "yes" ]]; then
    read -rp "Static IP address (e.g. 192.168.1.50/24): " STATIC_IP
    read -rp "Gateway (e.g. 192.168.1.1): " GATEWAY
    read -rp "DNS server [8.8.8.8]: " DNS
    DNS="${DNS:-8.8.8.8}"

    if [[ -n "$STATIC_IP" && -n "$GATEWAY" ]]; then
        ssh "$TARGET" "
nmcli con mod 'Wired connection 1' \
    ipv4.method manual \
    ipv4.addresses '${STATIC_IP}' \
    ipv4.gateway '${GATEWAY}' \
    ipv4.dns '${DNS}' 2>/dev/null || \
nmcli con mod 'Wired Connection 1' \
    ipv4.method manual \
    ipv4.addresses '${STATIC_IP}' \
    ipv4.gateway '${GATEWAY}' \
    ipv4.dns '${DNS}' 2>/dev/null || \
echo 'WARNING: Could not find wired connection profile to modify'

nmcli con up 'Wired connection 1' 2>/dev/null || \
nmcli con up 'Wired Connection 1' 2>/dev/null || true
"
        echo "Static IP configured: ${STATIC_IP}"
    fi
fi

echo ""

# ── Restart services ─────────────────────────────────────────────────────

echo "── Restart Services ──"
echo ""
read -rp "Restart the voice assistant now? [Y/n]: " RESTART
if [[ "${RESTART,,}" != "n" && "${RESTART,,}" != "no" ]]; then
    ssh "$TARGET" "systemctl restart voice-assistant"
    echo "Voice assistant restarted."
    echo ""
    echo "Monitor logs:"
    echo "  ssh ${TARGET} journalctl -u voice-assistant -f"
else
    echo "Restart manually when ready:"
    echo "  ssh ${TARGET} systemctl restart voice-assistant"
fi

echo ""
echo "============================================"
echo "  Configuration complete!"
echo "============================================"
echo ""
