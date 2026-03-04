#!/bin/bash
# Uninstall / Cleanup Script for Pi Server Setup
# WARNING: This script will remove services, users, and files created by the installer.
# It attempts to be safe but assumes standard installation paths were used.

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${RED}⚠️  WARNING: This script will UNINSTALL the following components: ${NC}"
echo "   - Monitoring Stack (Prometheus, Node Exporter, Alertmanager, Grafana)"
echo "   - Telegram Bot (Service and Files)"
echo "   - Samba (and configuration)"
echo "   - Webmin"
echo "   - Pi-hole (via official uninstaller)"
echo "   - Utility Scripts"
echo ""
echo -e "${YELLOW}It will NOT revert: System Updates, Static IP configurations (risky), or User creations (safety).${NC}"
echo ""
read -p "Are you DEFINITELY sure you want to proceed? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Helper to remove service
remove_service() {
    SERVICE=$1
    if systemctl is-active --quiet "$SERVICE" || systemctl is-enabled --quiet "$SERVICE"; then
        echo "Stopping and disabling $SERVICE..."
        systemctl stop "$SERVICE" || true
        systemctl disable "$SERVICE" || true
        rm -f "/etc/systemd/system/$SERVICE.service"
        echo "✅ $SERVICE removed."
    else
        echo "$SERVICE not found or already removed."
    fi
}

# 1. Telegram Bot
echo -e "\n${YELLOW}--- Removing Telegram Bot ---${NC}"
remove_service "telegram_bot"
if [ -d "/opt/pi-server-bot" ]; then
    echo "Removing /opt/pi-server-bot..."
    rm -rf "/opt/pi-server-bot"
fi

# 2. Monitoring Stack
echo -e "\n${YELLOW}--- Removing Monitoring Stack ---${NC}"
remove_service "prometheus"
remove_service "node_exporter"
remove_service "alertmanager"
remove_service "grafana-server"

echo "Removing Binaries..."
rm -f /usr/local/bin/prometheus /usr/local/bin/promtool
rm -f /usr/local/bin/node_exporter
rm -f /usr/local/bin/alertmanager /usr/local/bin/amtool

echo "Removing Configuration & Data..."
rm -rf /etc/prometheus /var/lib/prometheus
rm -rf /etc/alertmanager /var/lib/alertmanager
# Grafana is apt package
echo "Uninstalling Grafana package..."
apt-get remove --purge -y grafana || true
rm -rf /etc/grafana /var/lib/grafana

echo "Removing Service Users..."
userdel prometheus || true
userdel node_exporter || true
userdel alertmanager || true

# 3. Samba & Webmin
echo -e "\n${YELLOW}--- Removing Samba & Webmin ---${NC}"
read -p "Uninstall Samba? (This will also remove config /etc/samba/smb.conf) [y/N] " rm_samba
if [[ "$rm_samba" =~ ^[Yy]$ ]]; then
    apt-get remove --purge -y samba samba-common-bin || true
    rm -rf /etc/samba/
    echo "✅ Samba removed."
fi

read -p "Uninstall Webmin? [y/N] " rm_webmin
if [[ "$rm_webmin" =~ ^[Yy]$ ]]; then
    apt-get remove --purge -y webmin || true
    rm -f /etc/apt/sources.list.d/webmin.list
    rm -f /etc/apt/sources.list.d/webmin-stable.list
    echo "✅ Webmin removed."
fi

# 4. Utilities
echo -e "\n${YELLOW}--- Removing Utilities ---${NC}"
rm -f /usr/local/bin/send_report.sh
# Remove cron jobs added by us? (This is hard to catch perfectly, but we can try)
# We won't touch crontab blindly to avoid deleting user custom jobs.
echo "ℹ️  Note: Please manually check 'crontab -e' to remove any scheduled reports."

# 5. Pi-hole
echo -e "\n${YELLOW}--- Removing Pi-hole ---${NC}"
read -p "Uninstall Pi-hole? (Wraps 'pihole uninstall') [y/N] " rm_pihole
if [[ "$rm_pihole" =~ ^[Yy]$ ]]; then
    if command -v pihole >/dev/null; then
        pihole uninstall
    else
        echo "Pi-hole command not found."
    fi
fi

# Reload systemd
systemctl daemon-reload

echo -e "\n${GREEN}✅ Uninstall/Cleanup Complete.${NC}"
echo "Recommendation: Reboot your system to clear any lingering processes."
