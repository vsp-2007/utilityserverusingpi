#!/bin/bash
set -e
echo "--- Starting Localsend Installation ---"

# 1. Architecture Check
ARCH=$(uname -m)
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
    echo "⚠️  Warning: System architecture is $ARCH. Localsend ARM64 might not work."
    read -p "Continue anyway? [y/N] " cont
    if [[ ! "$cont" =~ ^[Yy]$ ]]; then exit 1; fi
fi

# 2. Download Localsend
# Using latest verified version (v1.17.0)
VERSION="1.17.0"
# Note the dash in "arm-64" for this release
DEB_URL="https://github.com/localsend/localsend/releases/download/v${VERSION}/LocalSend-${VERSION}-linux-arm-64.deb"
DEB_FILE="/tmp/localsend.deb"

echo "Downloading Localsend v${VERSION}..."
if wget -O "$DEB_FILE" "$DEB_URL"; then
    echo "Download successful."
else
    echo "❌ Download failed."
    exit 1
fi

# 3. Install
echo "Installing package..."
apt-get install -y "$DEB_FILE"
rm -f "$DEB_FILE"

# 4. Create Desktop Shortcut
DETECTED_USER=${SUDO_USER:-$(whoami)}
DESKTOP_DIR="/home/$DETECTED_USER/Desktop"

if [ -d "$DESKTOP_DIR" ]; then
    echo "Creating Desktop shortcut..."
    
    # Try to find where the app was installed
    if [ -f "/usr/share/applications/localsend_app.desktop" ]; then
        cp "/usr/share/applications/localsend_app.desktop" "$DESKTOP_DIR/Localsend.desktop"
    elif [ -f "/opt/localsend/share/applications/localsend_app.desktop" ]; then
         cp "/opt/localsend/share/applications/localsend_app.desktop" "$DESKTOP_DIR/Localsend.desktop"
    else
        # Manually create if missing
        cat <<EOF > "$DESKTOP_DIR/Localsend.desktop"
[Desktop Entry]
Name=LocalSend
Exec=/opt/localsend/localsend_app
Icon=/opt/localsend/data/flutter_assets/assets/img/logo-512.png
Type=Application
Terminal=false
Categories=Utility;FileTransfer;
EOF
    fi
    
    chmod +x "$DESKTOP_DIR/Localsend.desktop"
    chown "$DETECTED_USER:$DETECTED_USER" "$DESKTOP_DIR/Localsend.desktop"
    echo "✅ Shortcut created."
fi

# 5. Allow Firewall Port
PORT=53317
if command -v ufw >/dev/null; then
    if ufw status | grep -q "Status: active"; then
       ufw allow $PORT/tcp
       ufw allow $PORT/udp
       echo "Firewall: Allowed Localsend port $PORT"
    fi
fi

echo "--- Localsend Installed ---"
