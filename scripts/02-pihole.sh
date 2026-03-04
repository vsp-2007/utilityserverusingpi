#!/bin/bash
echo "--- Starting Pi-hole Setup ---"

# Generate setupVars.conf for unattended installation
# Only setting essential vars; installer will ask/default others or use these.
export PIHOLE_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n 1)
export IPV4_ADDRESS=$(hostname -I | cut -d' ' -f1)

# Ensure Dependencies for Blocklist Management (sqlite3)
if ! command -v sqlite3 &> /dev/null; then
    echo "Installing sqlite3 for database management..."
    apt-get install -y sqlite3
fi

# Check if Pi-hole is already installed

# Check if Pi-hole is already installed
# Check if Pi-hole is already installed
if command -v pihole >/dev/null; then
    echo "Pi-hole is already installed. Skipping installation."
else
    # Interactive Installation:
    # We do NOT create setupVars.conf, so the installer will launch the full TUI wizard.
    
    echo "Downloading Pi-hole installer..."
    curl -L https://install.pi-hole.net > basic-install.sh
    # User requested INTERACTIVE install to see the setup wizard.
    # We still pre-seed setupVars.conf, which the wizard will use as defaults.
    bash basic-install.sh
fi

# Add Blocklist?
# (Handled above before install)

# 5. Automated Whitelisting (AnudeepND)
echo "Configuring Automated Whitelisting (preventing common false positives)..."
# Download the Python script (whitelist.py) instead of the deprecated shell script
curl -sS https://raw.githubusercontent.com/anudeepND/whitelist/master/scripts/whitelist.py -o /usr/local/bin/pihole-whitelist.py
chmod +x /usr/local/bin/pihole-whitelist.py

# Run it immediately (silent mode) using python3
python3 /usr/local/bin/pihole-whitelist.py

# Add to cron for weekly updates (Sunday at 3:00 AM)
(crontab -l 2>/dev/null | grep -v "pihole-whitelist"; echo "0 3 * * 0 /usr/bin/python3 /usr/local/bin/pihole-whitelist.py >/dev/null 2>&1") | crontab -
echo "✅ Automated whitelisting configured (Weekly updates scheduled)."

# 6. Configure Blocklists via SQLite (The reliable method for v5+)
echo "Configuring Blocklists (Medium/Aggressive)..."

# Primary: StevenBlack Unified + Gambling + Porn (Covers Ads, Malware, 18+)
LIST_MAIN="https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/gambling-porn/hosts"
# Ads (Adaway)
LIST_ADS="https://adaway.org/hosts.txt"
# Malware (URLHaus)
LIST_MALWARE="https://urlhaus.abuse.ch/downloads/hostfile/"
# Telemetry
LIST_TELEMETRY="https://v.firebog.net/hosts/static/w3kbl.txt"

# Add to gravity.db
GRAVITY_DB="/etc/pihole/gravity.db"
for url in "$LIST_MAIN" "$LIST_ADS" "$LIST_MALWARE" "$LIST_TELEMETRY" "$PIHOLE_EXTRA_BLOCKLIST"; do
    if [ -n "$url" ]; then
        # Check if already exists
        if sqlite3 "$GRAVITY_DB" "SELECT COUNT(*) FROM adlist WHERE address = '$url';" | grep -q "0"; then
             sqlite3 "$GRAVITY_DB" "INSERT INTO adlist (address, enabled, comment) VALUES ('$url', 1, 'Added by Installer');"
             echo "Added blocklist: $url"
        else
             echo "Blocklist already present: $url"
        fi
    fi
done

# 6. Update Gravity
echo "Updating Gravity (Downloading Blocklists)..."
/usr/local/bin/pihole -g

# 6. Set Password
echo
echo "--- Pi-hole Security Setup ---"
echo "It is recommended to set a custom password for the Web Interface."
read -p "Do you want to set the Pi-hole Web Admin password now? [Y/n] " set_pw
if [[ ! "$set_pw" =~ ^[Nn]$ ]]; then
    # Wait for FTL to be ready
    echo "Waiting for Pi-hole FTL to start..."
    sleep 5
    
    # Force password reset using the accepted command in this version
    /usr/local/bin/pihole setpassword
else
    echo "You can set it later using 'pihole setpassword'"
fi


# 7. Final Security Warning
echo "---------------------------------------------------------"
echo "⚠️  IMPORTANT SECURITY WARNING ⚠️"
echo "When Pi-hole is installed, please ensure you configure your"
echo "DNS settings securely according to your specific network."
echo "Default configurations may vary. Do NOT expose port 53 to the internet."
echo "---------------------------------------------------------"

echo "--- Pi-hole Setup Complete ---"
