#!/bin/bash
echo "--- Starting System Setup ---"

# 1. Update & Upgrade
# 1. Update & Upgrade
echo "System Updates..."
read -p "Run APT Update & Upgrade? [Y/n] " run_update
if [[ ! "$run_update" =~ ^[Nn]$ ]]; then
    echo "Updating repositories..."
    # Pre-emptive cleanup of potentially conflicting Webmin repos to silence start-up warnings
    rm -f /etc/apt/sources.list.d/webmin.list /etc/apt/sources.list.d/webmin-stable.list
    apt-get update && apt-get upgrade -y
else
    echo "Skipping updates."
fi

apt-get install -y curl wget git vim htop btop python3 python3-venv python3-pip

# Enable RealVNC (standard on Pi OS)
# Enable RealVNC (standard on Pi OS)
if command -v raspi-config >/dev/null; then
    # Check if already enabled (0=enabled, 1=disabled)
    VNC_STATE=$(raspi-config nonint get_vnc)
    if [ "$VNC_STATE" -eq 0 ]; then
        echo "RealVNC is already ENABLED."
        read -p "Do you want to re-enable/reconfigure it? [y/N] " reconfig_vnc
    else
        reconfig_vnc="y"
    fi

    if [[ "$reconfig_vnc" =~ ^[Yy]$ ]]; then
        echo "Enabling RealVNC Server..."
        raspi-config nonint do_vnc 0
    else
        echo "Skipping VNC setup."
    fi
else
    echo "raspi-config not found. If you need VNC, please install/enable it manually."
fi

# 2. User Creation
DETECTED_USER=${SUDO_USER:-$(whoami)}
echo "Current user is: $DETECTED_USER"

read -p "Do you wish to create a new user (e.g. for desktop)? [y/N] " create_new_user
if [[ "$create_new_user" =~ ^[Yy]$ ]]; then
    read -p "Enter new username: " NEW_USER
    
    if [ -z "$NEW_USER" ]; then
        echo "Username cannot be empty. Skipping."
    elif id "$NEW_USER" &>/dev/null; then
        echo "User $NEW_USER already exists."
    else
        echo "Creating user $NEW_USER..."
        useradd -m -s /bin/bash "$NEW_USER"
        
        # Set Password
        echo "--------------------------------------------------"
        echo "Please set a password for $NEW_USER."
        passwd "$NEW_USER"
        echo "--------------------------------------------------"

        # Sudoers Option
        read -p "Do you wish to add $NEW_USER to the sudoers list? [y/N] " add_to_sudo
        if [[ "$add_to_sudo" =~ ^[Yy]$ ]]; then
            usermod -aG sudo "$NEW_USER"
            echo "✅ $NEW_USER added to sudoers."
        else
            echo "ℹ️  $NEW_USER was NOT added to sudoers."
        fi
    fi
else
    echo "Skipping user creation."
fi

# 3. Enable SSH
# 3. Enable SSH
echo "Checking SSH status..."
if systemctl is-active --quiet ssh; then
    echo "SSH is already ACTIVE."
    read -p "Do you want to re-enable/restart it? [y/N] " reconfig_ssh
else
    reconfig_ssh="y"
fi

if [[ "$reconfig_ssh" =~ ^[Yy]$ ]]; then
    echo "Enabling SSH..."
    if command -v raspi-config >/dev/null; then
        raspi-config nonint do_ssh 0
        echo "SSH enabled via raspi-config."
    else
        systemctl enable ssh
        systemctl start ssh
        echo "SSH enabled via systemctl."
    fi
else
    echo "Skipping SSH setup."
fi

# 4. Storage Optimization (Logs)
echo "Configuring Log Retention..."
# Limit systemd journal to 500MB
if ! grep -q "^SystemMaxUse=" /etc/systemd/journald.conf; then
    echo "SystemMaxUse=500M" >> /etc/systemd/journald.conf
    systemctl restart systemd-journald
    echo "Journald limited to 500MB."
else
    sed -i "s/^SystemMaxUse=.*/SystemMaxUse=500M/" /etc/systemd/journald.conf
    systemctl restart systemd-journald
    echo "Journald limit updated to 500MB."
fi

echo "--- System Setup Complete ---"
