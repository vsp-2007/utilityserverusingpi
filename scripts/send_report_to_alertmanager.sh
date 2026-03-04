#!/bin/bash
# Send System Status Report to Alertmanager (Local)
# This script sends a "DailyReport" alert to Alertmanager, which formats it and forwards it to Telegram.

# 1. Gather System Stats
HOSTNAME=$(hostname)
UPTIME=$(uptime -p)
KERNEL=$(uname -r)
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

# 2. Format the Message (HTML allowed in our Alertmanager template)
MESSAGE="
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

# 3. Construct JSON Payload using Python to ensure valid escaping
# JSON strings cannot have literal newlines, so we use Python to dump it safely.
JSON_PAYLOAD=$(python3 -c "
import json
import socket

payload = [{
    'labels': {
        'alertname': 'DailyReport',
        'severity': 'info',
        'instance': '$HOSTNAME'
    },
    'annotations': {
        'message': '''$MESSAGE'''
    }
}]
print(json.dumps(payload))
")

# 4. Send to Alertmanager API
# Using 127.0.0.1 to avoid IPv6 localhost issues
# -v for verbose to see connection errors in logs if any
# -H "Content-Type: application/json" is required for v2 API
echo "Posting status to Alertmanager..."
RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" -XPOST -H "Content-Type: application/json" -d "$JSON_PAYLOAD" http://127.0.0.1:9093/api/v2/alerts)

if [ "$RESPONSE" -eq 200 ]; then
    echo "✅ Status Report sent successfully (HTTP 200)."
else
    echo "❌ Failed to send Status Report. HTTP Code: $RESPONSE"
    echo "   Ensure Alertmanager is running (systemctl status alertmanager)."
fi
