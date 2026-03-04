#!/bin/bash
echo "--- Starting Utilities Setup ---"

# Ensure SCRIPT_DIR is set (fallback if not exported)
if [ -z "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Load Config if variables are missing
if [ -z "$TELEGRAM_ADMIN_TOKEN" ] && [ -f "$SCRIPT_DIR/setup.conf" ]; then
    echo "Loading configuration from setup.conf..."
    set -a
    source "$SCRIPT_DIR/setup.conf"
    set +a
fi

# FALLBACK: Try to recover tokens from existing Alertmanager config
if [ -z "$TELEGRAM_ADMIN_TOKEN" ] && [ -f /etc/alertmanager/alertmanager.yml ]; then
    echo "Attempting to recover tokens from existing Alertmanager config..."
    RECOVERED_TOKEN=$(grep "bot_token" /etc/alertmanager/alertmanager.yml | awk -F"'" '{print $2}' | tr -d '\r')
    if [ -z "$RECOVERED_TOKEN" ]; then
        RECOVERED_TOKEN=$(grep "bot_token" /etc/alertmanager/alertmanager.yml | awk -F'"' '{print $2}' | tr -d '\r')
    fi
    RECOVERED_CHAT=$(grep "chat_id" /etc/alertmanager/alertmanager.yml | awk '{print $2}' | tr -d '\r')
    
    if [ -n "$RECOVERED_TOKEN" ] && [ -n "$RECOVERED_CHAT" ]; then
        echo "✅ Recovered tokens from Alertmanager."
        TELEGRAM_ADMIN_TOKEN="$RECOVERED_TOKEN"
        TELEGRAM_ADMIN_CHAT_ID="$RECOVERED_CHAT"
    fi
fi

# 1. Status Reports (Primary Utility)
# Using direct Telegram script for reliability (Bypasses Alertmanager deduplication/formatting issues)
echo "Configuring Status Reports (Cron)..."
REPORT_SCRIPT="$SCRIPT_DIR/scripts/send_report.sh"
TARGET_SCRIPT="/usr/local/bin/send_report.sh"

if [ ! -f "$REPORT_SCRIPT" ]; then
    echo "Error: $REPORT_SCRIPT not found!"
    exit 1
fi

# Move script to a persistent location
cp "$REPORT_SCRIPT" "$TARGET_SCRIPT"
chmod +x "$TARGET_SCRIPT"

# Inject Tokens into the target script
if [ -n "$TELEGRAM_ADMIN_TOKEN" ] && [ -n "$TELEGRAM_ADMIN_CHAT_ID" ]; then
    echo "Injecting Admin Bot credentials into reporting script..."
    sed -i "s|PLACEHOLDER_TOKEN|$TELEGRAM_ADMIN_TOKEN|g" "$TARGET_SCRIPT"
    sed -i "s|PLACEHOLDER_CHAT_ID|$TELEGRAM_ADMIN_CHAT_ID|g" "$TARGET_SCRIPT"
    
    if grep -q "PLACEHOLDER_TOKEN" "$TARGET_SCRIPT"; then
        echo "❌ Critical: Token injection failed."
    else
        echo "✅ Token injection verified."
    fi
else
    echo "Warning: Admin Bot credentials missing. Report script will fail until updated."
fi

# Add Cron Jobs
# We use a temporary file to avoid messing up existing crons.
CRON_FILE=$(mktemp)
crontab -l > "$CRON_FILE" 2>/dev/null

# Remove existing entries to avoid duplicates if re-ran
sed -i '/send_report.sh/d' "$CRON_FILE"

# Add Reboot Job
echo "@reboot /usr/local/bin/send_report.sh" >> "$CRON_FILE"
# Add Daily Job (08:00 AM)
echo "0 8 * * * /usr/local/bin/send_report.sh" >> "$CRON_FILE"

# Install new cron file
crontab "$CRON_FILE"
rm "$CRON_FILE"
echo "Status reports scheduled (Reboot & Daily at 08:00)."

# Add any other utils here

# Trigger Immediate Report (Visual Confirmation)
# Trigger Immediate Report (Visual Confirmation)
if [ -n "$TELEGRAM_ADMIN_TOKEN" ] && [ -n "$TELEGRAM_ADMIN_CHAT_ID" ]; then
    echo "Sending initial status report..."
    /usr/local/bin/send_report.sh
else
    echo "Skipping initial status report (Admin Bot credentials not set)."
fi

echo "--- Utilities Setup Complete ---"
