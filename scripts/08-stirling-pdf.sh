#!/bin/bash
set -e
echo "--- Starting Stirling-PDF Setup (Manual/JAR) ---"

# Variables
APP_DIR="/opt/Stirling-PDF"
USER_NAME="stirlingpdf"
# User requests NO LOGIN -> Use standard JAR (not 'with-login')
DOWNLOAD_URL="https://github.com/Stirling-Tools/Stirling-PDF/releases/download/v2.4.5/Stirling-PDF.jar"
JAR_NAME="Stirling-PDF.jar"
PORT="8080"

# 1. Check for Existing Installation
if [ -f "$APP_DIR/$JAR_NAME" ]; then
    echo "Stirling-PDF appears to be installed at $APP_DIR/$JAR_NAME."
    read -p "Do you want to REINSTALL it? (This will overwrite the JAR) [y/N] " reinstall
    if [[ ! "$reinstall" =~ ^[Yy]$ ]]; then
        echo "Skipping installation steps..."
        echo "Ensuring service is running..."
        systemctl restart stirling-pdf
        echo "✅ Service restarted."
        exit 0
    fi
    echo "Proceeding with re-installation..."
fi

# 2. Install Dependencies
echo "Installing Dependencies (Java 21, LibreOffice, Tesseract, Python)..."
apt-get update

if ! apt-get install -y openjdk-21-jdk; then
    echo "⚠️ openjdk-21-jdk not found. Trying 17 or generic default..."
    apt-get install -y default-jdk
fi

apt-get install -y libreoffice-writer libreoffice-calc libreoffice-impress \
    tesseract-ocr tesseract-ocr-eng \
    python3 python3-pip python3-venv \
    ca-certificates curl gnupg wget dphys-swapfile

# 1b. Configure Swap (Crucial for Pi 4 with heavy Java apps)
# Check if we need to increase swap
if [ -f /etc/dphys-swapfile ]; then
    CURRENT_SWAP=$(grep "^CONF_SWAPSIZE=" /etc/dphys-swapfile | cut -d= -f2)
    # Default to 0 if empty to avoid syntax error
    if [ -z "$CURRENT_SWAP" ]; then CURRENT_SWAP=0; fi
    
    if [ "$CURRENT_SWAP" -lt 2048 ]; then
        echo "Optimizing Swap for Stirling-PDF (Increasing to 2GB)..."
        sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
        systemctl restart dphys-swapfile
        echo "✅ Swap increased."
    fi
fi

# 2. Create Service User
if ! id "$USER_NAME" &>/dev/null; then
    echo "Creating system user '$USER_NAME'..."
    useradd -r -s /bin/false -d "$APP_DIR" "$USER_NAME"
fi

# 3. Setup Directory and Download
echo "Setting up application directory..."
mkdir -p "$APP_DIR"
# Pre-create logs/configs to ensure permissions
mkdir -p "$APP_DIR/logs" "$APP_DIR/configs" "$APP_DIR/customFiles"

# Stop service if running to allow file overwrite
systemctl stop stirling-pdf || true

echo "Downloading Stirling-PDF from $DOWNLOAD_URL..."
rm -f "$APP_DIR/$JAR_NAME"

# Use wget for better handling of GitHub redirects in some environments
if wget -O "$APP_DIR/$JAR_NAME" "$DOWNLOAD_URL"; then
    echo "Download completed."
else
    echo "❌ Error: Failed to download Stirling-PDF. Detailed output:"
    wget -d --spider "$DOWNLOAD_URL"
    exit 1
fi

# Validation Mechanism
FILE_SIZE=$(stat -c%s "$APP_DIR/$JAR_NAME")
echo "Downloaded file size: $FILE_SIZE bytes"

# Standard JAR is also large (approx 100MB+ for v2.4.5).
if [ "$FILE_SIZE" -lt 50000000 ]; then
    echo "❌ Error: File too small ($FILE_SIZE bytes). Likely corrupt or partial download."
    echo "Deleting corrupt file..."
    rm "$APP_DIR/$JAR_NAME"
    exit 1
fi

# 3b. Configure No-Login (New Requirement)
echo "Configuring No-Login Mode..."
# Create settings.yml with security.enableLogin: false
cat <<EOF > "$APP_DIR/settings.yml"
security:
  enableLogin: false
system:
  # Disable heavy features for Pi optimization
  enableAlphaFunctionality: false
EOF
chmod 644 "$APP_DIR/settings.yml"


# Fix permissions clearly
chown -R "$USER_NAME:$USER_NAME" "$APP_DIR"
chmod 755 "$APP_DIR"
chmod 644 "$APP_DIR/$JAR_NAME"

# 4. Create Systemd Service
echo "Creating Systemd Service..."
cat <<EOF > /etc/systemd/system/stirling-pdf.service
[Unit]
Description=Stirling-PDF Service
After=syslog.target network.target

[Service]
SuccessExitStatus=143
User=$USER_NAME
Group=$USER_NAME
Type=simple
# Crucial: Set working directory so logs/configs are written to the right place
WorkingDirectory=$APP_DIR
# Lower priority (higher nice value) to prevent CPU starvation of other processes
Nice=10

Environment="server.port=$PORT"
Environment="system.defaultLocale=en-US"
Environment="SYSTEM_DEFAULTLOCALE=en-US"
Environment="SECURITY_ENABLELOGIN=false"
Environment="DOCKER_ENABLE_SECURITY=false"
Environment="DISABLE_ADDITIONAL_FEATURES=true"

# JVM Tuning for Pi (CPU & Memory Optimization)
# -Xms512m -Xmx1024m: Memory limits
# -XX:+UseSerialGC: Use single-threaded GC to reduce CPU overhead
# -XX:TieredStopAtLevel=1: Reduce JIT compilation CPU usage (faster startup, slightly lower peak perf)
# -Djava.security.egd=file:/dev/./urandom: Improve startup time if entropy is low
ExecStart=/usr/bin/java -Xms512m -Xmx1024m -XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Djava.security.egd=file:/dev/./urandom -jar $APP_DIR/$JAR_NAME
ExecStop=/bin/kill -15 \$MAINPID
Restart=always
RestartSec=10
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable stirling-pdf
echo "Starting Stirling-PDF Service..."
systemctl restart stirling-pdf

# 5. Create Desktop Shortcut
DETECTED_USER=${SUDO_USER:-$(whoami)}
DESKTOP_DIR="/home/$DETECTED_USER/Desktop"

if [ -d "$DESKTOP_DIR" ]; then
    echo "Creating Desktop shortcut..."
    # Download an icon (optional, using generic text for now)
    cat <<EOF > "$DESKTOP_DIR/Stirling-PDF.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Stirling PDF
Comment=Local PDF Tools
Exec=xdg-open http://localhost:$PORT
Icon=utilities-terminal
Path=
Terminal=false
StartupNotify=false
EOF
    
    chmod +x "$DESKTOP_DIR/Stirling-PDF.desktop"
    chown "$DETECTED_USER:$DETECTED_USER" "$DESKTOP_DIR/Stirling-PDF.desktop"
    echo "✅ Desktop shortcut created."
else
    echo "Desktop directory not found. Skipping shortcut."
fi

# 6. Configure Firewall (UFW)
if command -v ufw >/dev/null; then
    if ufw status | grep -q "Status: active"; then
        echo "Opening Port $PORT..."
        ufw allow $PORT/tcp
    fi
fi

echo "--- Stirling-PDF Setup Complete ---"
echo "Access URL: http://localhost:$PORT"
