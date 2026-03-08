#!/bin/bash

# ANSI Color Codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Helper Functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
  log_error "Please run as root"
  exit 1
fi

log_info "Installing Cockpit..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y cockpit

log_info "Configuring Cockpit to listen on port 9091..."
mkdir -p /etc/systemd/system/cockpit.socket.d

cat << 'EOF' > /etc/systemd/system/cockpit.socket.d/override.conf
[Socket]
ListenStream=
ListenStream=9091
EOF

log_info "Restarting Cockpit socket..."
systemctl daemon-reload
systemctl restart cockpit.socket
systemctl enable cockpit.socket

log_info "Cockpit installed successfully and listening on port 9091."
