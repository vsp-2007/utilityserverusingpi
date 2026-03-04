#!/bin/bash
set -e
echo "--- Starting Wazuh Manager Setup ---"

# Check if Root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

# Variables
WAZUH_CONFIG="/var/ossec/etc/ossec.conf"
LOG2RAM_CONF="/etc/log2ram.conf"
TELEGRAM_SCRIPT="/var/ossec/integrations/custom-telegram.py"
TELEGRAM_CONF="/var/ossec/integrations/telegram-config.json"

# Load Configuration (Assumes setup.conf is loaded by install.sh or available locally)
if [ -f "setup.conf" ]; then
    source setup.conf
elif [ -f "/etc/pi-server-credentials.conf" ]; then
    source /etc/pi-server-credentials.conf
fi

# 1. Check for Existing Installation
if systemctl is-active --quiet wazuh-manager; then
    echo "Wazuh Manager is currently running."
    read -p "Do you want to REINSTALL/RECONFIGURE it? [y/N] " reinstall
    if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
        echo "Skipping Wazuh installation..."
        exit 0
    fi
    echo "Proceeding with re-configuration..."
elif [ -d "/var/ossec" ]; then
    echo "Wazuh directory exists but service is not active. Proceeding to fix/reinstall."
fi

# 2. Install log2ram (if not present) and configure it
echo "Setting up Log2Ram for SD Card protection..."
if ! command -v log2ram >/dev/null; then
    echo "Installing log2ram..."
    echo "deb http://packages.azlux.fr/debian/ bookworm main" | tee /etc/apt/sources.list.d/azlux.list
    wget -qO - https://azlux.fr/repo.gpg.key | apt-key add -
    apt-get update
    apt-get install -y log2ram
fi

# Increase log2ram size for Wazuh bursts and add custom mount
if [ -f "$LOG2RAM_CONF" ]; then
    # Increase base size to 200M
    sed -i 's/^SIZE=.*/SIZE=200M/' "$LOG2RAM_CONF"
    
    # Check if PATH_DISK contains wazuh logs
    if ! grep -q "PATH_DISK.*/var/ossec/logs" "$LOG2RAM_CONF"; then
         # Ensure log2ram manages /var/ossec/logs as well
         # Note: log2ram officially supports multiple paths via PATH_DISK natively in recent versions
         CURRENT_PATHS=$(grep "^PATH_DISK=" "$LOG2RAM_CONF" | cut -d'"' -f2)
         if [ -z "$CURRENT_PATHS" ] || [ "$CURRENT_PATHS" == "/var/log" ]; then
             sed -i 's|^PATH_DISK=.*|PATH_DISK="/var/log;/var/ossec/logs"|' "$LOG2RAM_CONF"
         else
             # If it already has multiple paths but not wazuh
             if [[ "$CURRENT_PATHS" != *"/var/ossec/logs"* ]]; then
                 sed -i "s|^PATH_DISK=.*|PATH_DISK=\"$CURRENT_PATHS;/var/ossec/logs\"|" "$LOG2RAM_CONF"
             fi
         fi
    fi
    echo "Log2Ram configured for 200M and /var/ossec/logs."
    # Restart log2ram (careful, it syncs to disk)
    systemctl restart log2ram || true
fi

# 3. Add Wazuh Repository
echo "Adding Wazuh Repositories..."
apt-get install -y curl apt-transport-https unzip wget libcap2-bin software-properties-common lsb-release gnupg2
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import && chmod 644 /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" | tee /etc/apt/sources.list.d/wazuh.list
apt-get update

# 4. Install Wazuh Manager
echo "Installing Wazuh Manager..."
apt-get install -y wazuh-manager

systemctl stop wazuh-manager

# 5. Optimize ossec.conf for Raspberry Pi
echo "Optimizing ossec.conf for Raspberry Pi..."

# We are going to back up the original and strictly modify the required blocks using xmlstarlet or sed, 
# but replacing the file entirely with a hyper-optimized template is safer for Pi.
cp "$WAZUH_CONFIG" "$WAZUH_CONFIG.bak"

# 5.1 Disable global logging to save SD card IO
sed -i 's/<logall>yes/<logall>no/' "$WAZUH_CONFIG"
sed -i 's/<logall_json>yes/<logall_json>no/' "$WAZUH_CONFIG"

# 5.2 Tune Syscheck (FIM)
sed -i '/<syscheck>/,/<\/syscheck>/ {
  s/<frequency>.*<\/frequency>/<frequency>172800<\/frequency>\n    <scan_time>02:00<\/scan_time>\n    <scan_day>wednesday,sunday<\/scan_day>/
  s/<directories check_all="yes">\/etc,\/usr\/bin,\/usr\/sbin<\/directories>/<directories check_all="yes">\/etc,\/usr\/bin,\/usr\/sbin<\/directories>/
  # Ensure realtime is off
  s/<directories check_all="yes" realtime="yes">/<directories check_all="yes">/g
}' "$WAZUH_CONFIG"

# 5.3 Tune Rootcheck
sed -i '/<rootcheck>/,/<\/rootcheck>/ {
  s/<frequency>.*<\/frequency>/<frequency>604800<\/frequency>\n    <scan_time>03:00<\/scan_time>\n    <scan_day>tuesday<\/scan_day>/
}' "$WAZUH_CONFIG"

# 5.4 Tune Vulnerability Detector (NVD) - 7 Days
sed -i '/<vulnerability-detector>/,/<\/vulnerability-detector>/ {
  s/<interval>.*<\/interval>/<interval>7d<\/interval>/
}' "$WAZUH_CONFIG"

# 5.5 Disable Unwanted Modules rigidly (AWS, GCP, Azure, GitHub, OpenSCAP, CIS-CAT, Windows/Mac rules)
# Wazuh config allows "no" for enabled.
for module in "wodle name=\"aws-s3\"" "wodle name=\"gcp-pubsub\"" "wodle name=\"azure-logs\"" "wodle name=\"github\"" "wodle name=\"syscollector\"" "wodle name=\"osquery\"" "wodle name=\"cis-cat\"" "oscap"; do
    # Regex hack to switch <disabled>no</disabled> to <disabled>yes</disabled> or <enabled>no</enabled>
    # Simplest approach on standard wazuh XML without xmlstarlet:
    sed -i "/<$module>/,/<\// s/<disabled>no<\/disabled>/<disabled>yes<\/disabled>/" "$WAZUH_CONFIG"
    sed -i "/<$module>/,/<\// s/<enabled>yes<\/enabled>/<enabled>no<\/enabled>/" "$WAZUH_CONFIG"
done

# 6. Telegram Integration Hook
echo "Setting up Telegram Integration..."
cp scripts/custom-telegram.py "$TELEGRAM_SCRIPT"
chmod 750 "$TELEGRAM_SCRIPT"
chown root:wazuh "$TELEGRAM_SCRIPT"

# Write Credentials to json for the script
cat <<EOF > "$TELEGRAM_CONF"
{
  "TELEGRAM_ADMIN_TOKEN": "$TELEGRAM_ADMIN_TOKEN",
  "TELEGRAM_ADMIN_CHAT_ID": "$TELEGRAM_ADMIN_CHAT_ID"
}
EOF
chmod 640 "$TELEGRAM_CONF"
chown root:wazuh "$TELEGRAM_CONF"

# Add integration block to ossec.conf before the closing </ossec_config>
if ! grep -q "<name>custom-telegram</name>" "$WAZUH_CONFIG"; then
    sed -i '/<\/ossec_config>/i \
  <integration>\n\
    <name>custom-telegram</name>\n\
    <hook_url>none</hook_url>\n\
    <level>7</level>\n\
    <rule_id>503,514,20002</rule_id>\n\
    <alert_format>json</alert_format>\n\
  </integration>' "$WAZUH_CONFIG"
fi

# 7. Setup Daily JSON Export to Telegram (Periodic Pushes)
echo "Setting up Daily JSON Export Cron..."
cat << 'EOF' > /etc/cron.daily/wazuh_telegram_export
#!/bin/bash
# Zips yesterday's alerts.json and sends it to the Admin Telegram Bot if it exists
LOG_DIR="/var/ossec/logs/alerts/$(date -d "yesterday" +%Y/%b)"
LOG_FILE="$LOG_DIR/ossec-alerts-$(date -d "yesterday" +%d).json.gz" # Wazuh auto-compresses daily
CONF="/var/ossec/integrations/telegram-config.json"

if [ -f "$LOG_FILE" ] && [ -f "$CONF" ]; then
    TOKEN=$(grep -o '"TELEGRAM_ADMIN_TOKEN": "[^"]*' "$CONF" | cut -d'"' -f4)
    CHAT_ID=$(grep -o '"TELEGRAM_ADMIN_CHAT_ID": "[^"]*' "$CONF" | cut -d'"' -f4)
    
    if [ -n "$TOKEN" ] && [ -n "$CHAT_ID" ]; then
       # Copy to tmp as a cleaner name 
       cp "$LOG_FILE" /tmp/wazuh_alerts_yesterday.json.gz
       curl -s -F chat_id="$CHAT_ID" -F document=@"/tmp/wazuh_alerts_yesterday.json.gz" -F caption="📅 Daily Wazuh JSON Alerts Dump" "https://api.telegram.org/bot$TOKEN/sendDocument" > /dev/null
       rm /tmp/wazuh_alerts_yesterday.json.gz
    fi
fi
EOF
chmod +x /etc/cron.daily/wazuh_telegram_export

# 8. Logrotate for Wazuh Alerts (Keep only 7 days to save space since we export them)
echo "Setting up Logrotate for Wazuh..."
cat <<EOF > /etc/logrotate.d/wazuh
/var/ossec/logs/alerts/alerts.json /var/ossec/logs/alerts/alerts.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 0640 wazuh wazuh
    sharedscripts
    postrotate
        systemctl restart wazuh-manager > /dev/null 2>/dev/null || true
    endscript
}
EOF

# 9. Start Services
echo "Starting Wazuh Manager..."
systemctl daemon-reload
systemctl enable wazuh-manager
systemctl start wazuh-manager

echo "--- Wazuh Setup Complete ---"
echo "Daily checks are configured automatically."
echo "You can manually trigger a check via Telegram using /check."
