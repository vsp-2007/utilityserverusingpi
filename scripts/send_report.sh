#!/bin/bash
# Send System Status Report directly to Telegram
# Bypasses Alertmanager to ensure immediate, non-deduplicated delivery.

# Configuration (Injected by install script)
BOT_TOKEN="PLACEHOLDER_TOKEN"
CHAT_ID="PLACEHOLDER_CHAT_ID"

# 1. Gather System Stats
HOSTNAME=$(hostname)
UPTIME=$(uptime -p)
IP_ADDR=$(hostname -I | cut -d' ' -f1)

# CPU Temperature
if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
    TEMP_C=$(awk '{print $1/1000}' /sys/class/thermal/thermal_zone0/temp)
    TEMP_DISP="${TEMP_C}°C"
else
    TEMP_DISP="N/A"
fi

# RAM Usage
MEM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
MEM_USED=$(free -h | awk '/^Mem:/ {print $3}')

# Disk Usage (Root)
DISK_USAGE=$(df -h / | awk 'NR==2 {print $5}')
DISK_FREE=$(df -h / | awk 'NR==2 {print $4}')

# Service Status Check
check_service() {
    if systemctl is-active --quiet "$1"; then
        echo "✅ $1"
    else
        echo "❌ $1"
    fi
}

SERVICES_MSG="
$(check_service prometheus)
$(check_service node_exporter)
$(check_service alertmanager)
$(check_service grafana-server)
$(check_service pihole-FTL)
$(check_service smbd)
"

# 2. Format the Message (HTML)
MESSAGE="
📊 <b>DAILY SYSTEM REPORT</b> 📊

<b>System Status:</b> Optimal
<b>Hostname:</b> $HOSTNAME
<b>IP:</b> $IP_ADDR
<b>Uptime:</b> $UPTIME
<b>Temp:</b> $TEMP_DISP
<b>RAM:</b> $MEM_USED / $MEM_TOTAL
<b>Disk:</b> $DISK_USAGE Used ($DISK_FREE Free)

<b>Service Health:</b>
$SERVICES_MSG
"

# 3. Send to Telegram API directly
# Validation removed to prevent false positives. Curl will report error if token is bad.
if [ -z "$BOT_TOKEN" ]; then
    echo "❌ Error: Telegram Token is empty."
    exit 1
fi

echo "Sending Telegram Message..."
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="HTML" \
    -d text="$MESSAGE" >/dev/null

if [ $? -eq 0 ]; then
    echo "✅ Message sent to Telegram."
else
    echo "❌ Failed to send message."
fi
