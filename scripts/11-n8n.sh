#!/bin/bash
set -e

# ANSI Color Codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Helper Functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "--- Starting n8n Setup (Native Node.js) ---"

# Variables
USER_NAME="n8n"
APP_DIR="/var/lib/n8n"
PORT="5678"

# 1. Install Node.js 20.x dependency
log_info "Installing dependencies (Node.js 20.x)..."
apt-get update
# Install prerequisites for nodesource script
apt-get install -y ca-certificates curl gnupg

# Download and run NodeSource setup script
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | cut -d. -f1)" != "v20" ]; then
    log_info "Downloading Node.js 20 setup script..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
else
    log_info "Node.js 20.x is already installed."
fi

# 2. Configure npm network resilience for large downloads
log_info "Configuring npm network resilience..."
npm config set fetch-retries 5
npm config set fetch-retry-mintimeout 20000
npm config set fetch-retry-maxtimeout 120000

# Install n8n globally via npm with a retry loop
if ! command -v n8n >/dev/null 2>&1; then
    log_info "Installing n8n globally via npm (this may take 5-10 minutes)..."
    
    # Retry loop for initial installation
    MAX_RETRIES=3
    RETRY_COUNT=0
    SUCCESS=false
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if npm install n8n -g; then
            SUCCESS=true
            break
        else
            RETRY_COUNT=$((RETRY_COUNT+1))
            log_warn "npm install failed (Network issue?). Retrying ($RETRY_COUNT/$MAX_RETRIES) in 10 seconds..."
            sleep 10
        fi
    done
    
    if [ "$SUCCESS" = false ]; then
        log_error "Failed to install n8n after $MAX_RETRIES attempts. Please check your internet connection and try again."
        exit 1
    fi
else
    log_info "n8n is already installed. Attempting update..."
    # We use a simple retry wrapper for update as well just in case
    npm update n8n -g || log_warn "Update encountered a network error, keeping existing version."
fi

# 3. Create Service User
if ! id "$USER_NAME" &>/dev/null; then
    log_info "Creating system user '$USER_NAME'..."
    useradd -r -s /bin/false -m -d "$APP_DIR" "$USER_NAME"
else
    log_info "System user '$USER_NAME' already exists."
fi

# Set permissions
chown -R "$USER_NAME:$USER_NAME" "$APP_DIR"

# 4. Create Environment File
log_info "Configuring n8n environment..."
mkdir -p /etc/n8n
cat <<EOF > /etc/n8n/env
# The port n8n should listen on
N8N_PORT=$PORT

# The URL you will access n8n from
WEBHOOK_URL=http://n8n.home

# Secure local credentials by restricting them to the file system owner
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true

# Disable secure cookies since Nginx handles the reverse proxy (and Tailscale encrypts traffic)
N8N_SECURE_COOKIE=false
EOF

chmod 600 /etc/n8n/env
chown -R "$USER_NAME:$USER_NAME" /etc/n8n

# 5. Create Systemd Service
log_info "Creating Systemd Service..."
cat <<EOF > /etc/systemd/system/n8n.service
[Unit]
Description=n8n Automation Engine
After=network.target

[Service]
Type=simple
User=$USER_NAME
Group=$USER_NAME
EnvironmentFile=/etc/n8n/env

# Path to the global n8n executable
ExecStart=/usr/bin/node /usr/bin/n8n start
Restart=always
RestartSec=10
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF

# 6. Start and Enable Service
log_info "Starting n8n Service..."
systemctl daemon-reload
systemctl enable n8n
systemctl restart n8n

# 7. Configure Firewall (UFW) if present
if command -v ufw >/dev/null; then
    if ufw status | grep -q "Status: active"; then
        log_info "Opening Port $PORT in UFW..."
        ufw allow $PORT/tcp
    fi
fi

log_info "✅ n8n Setup Complete."
echo "Access URL: http://localhost:$PORT (or http://n8n.home once Nginx is configured)"
