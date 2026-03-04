#!/bin/bash
echo "--- Starting Network Setup ---"

# 1. Install Tailscale
if ! command -v tailscale >/dev/null; then
    echo "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
else
    echo "Tailscale already installed."
fi

# 2. Authenticate Tailscale
# 2. Authenticate Tailscale
# Check if already logged in?
if tailscale status >/dev/null 2>&1; then
    echo "Tailscale is already CONNECTED."
    read -p "Do you want to re-authenticate (logout & login)? [y/N] " reauth_ts
    if [[ "$reauth_ts" =~ ^[Yy]$ ]]; then
        echo "Logging out..."
        tailscale logout
        # Fall through to login logic below
    else
        echo "Skipping Tailscale authentication."
        # Using a flag to skip the next block
        SKIP_TS_LOGIN=true
    fi
fi

if [ "$SKIP_TS_LOGIN" != "true" ]; then
    # Exit Node Prompt
    read -p "Advertise this device as a Tailscale Exit Node? [y/N] " advertise_exit
    TS_ARGS=""
    if [[ "$advertise_exit" =~ ^[Yy]$ ]]; then
        echo "Will advertise as Exit Node..."
        TS_ARGS="--advertise-exit-node"
    fi

    if [ -n "$TAILSCALE_AUTH_KEY" ]; then
        echo "Bringing Tailscale up with provided key..."
        tailscale up --authkey="$TAILSCALE_AUTH_KEY" $TS_ARGS
    else
        echo "No auth key provided and not connected."
        echo "Please run 'sudo tailscale up $TS_ARGS' manually later, or authenticate now."
        read -p "Run interactive login now? [y/N] " run_login
        if [[ $run_login =~ ^[Yy]$ ]]; then
            tailscale up $TS_ARGS
        fi
    fi

    if [[ "$advertise_exit" =~ ^[Yy]$ ]]; then
        echo
        echo "⚠️  ACTION REQUIRED: Enable Exit Node in Admin Panel"
        echo "   Go to: https://login.tailscale.com/admin/machines"
        echo "   Find this device -> Edit Route Settings -> Enable 'Use as exit node'"
    fi
    
    echo
    echo "💡 TIP: Set this Pi as your Global DNS for Ad Blocking everywhere!"
    echo "   Go to: https://login.tailscale.com/admin/dns"
    echo "   Nameservers -> Global Name Servers -> Add Nameserver -> Start typing this device's name"
    echo "   Ensure 'Override local DNS' is ON."
fi

# 3. Static IP Configuration (Optional)
# This is risky on remote connections.
echo
echo "--- Static IP Configuration ---"
echo "WARNING: Changing IP configuration remotely can disconnect you."
echo "It is recommended to set a Static DHCP Reservation in your router instead."
read -p "Do you want to configure a static IP on this device? [y/N] " set_static
if [[ $set_static =~ ^[Yy]$ ]]; then
    # Helper to get current info
    CURRENT_IP=$(hostname -I | cut -d' ' -f1)
    ROUTER=$(ip route | grep default | awk '{print $3}')
    
    echo "Current IP: $CURRENT_IP"
    echo "Gateway: $ROUTER"
    
    read -p "Enter desired Static IP [$CURRENT_IP]: " STATIC_IP
    STATIC_IP=${STATIC_IP:-$CURRENT_IP}
    
    read -p "Enter Gateway (Router IP) [$ROUTER]: " GATEWAY_IP
    GATEWAY_IP=${GATEWAY_IP:-$ROUTER}
    
    read -p "Enter DNS Server [8.8.8.8]: " STR_DNS
    STR_DNS=${STR_DNS:-8.8.8.8}
    
    echo "Configuring /etc/dhcpcd.conf (backup created)..."
    cp /etc/dhcpcd.conf /etc/dhcpcd.conf.bak
    
    cat <<EOT >> /etc/dhcpcd.conf

# Static IP Configuration by Installer
interface eth0
static ip_address=$STATIC_IP/24
static routers=$GATEWAY_IP
static domain_name_servers=$STR_DNS
EOT
    echo "Configuration appended. Reboot required to take effect."
else
    echo "Skipping static IP configuration."
fi

echo "--- Network Setup Complete ---"
