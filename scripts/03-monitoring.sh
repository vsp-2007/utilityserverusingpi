#!/bin/bash
set -e
echo "--- Starting Monitoring Stack Setup ---"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Firewall Check (Optional but helpful)
if command -v ufw >/dev/null; then
    echo "UFW detected. Opening monitoring ports..."
    ufw allow 3000/tcp || true # Grafana
    ufw allow 9090/tcp || true # Prometheus
    ufw allow 9093/tcp || true # Alertmanager
    ufw allow 9100/tcp || true # Node Exporter
fi


ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
if [[ "$ARCH" == "aarch64" ]]; then
    PROM_ARCH="linux-arm64"
    NODE_ARCH="linux-arm64"
    ALERT_ARCH="linux-arm64"
elif [[ "$ARCH" == "armv7l" ]]; then
    PROM_ARCH="linux-armv7"
    NODE_ARCH="linux-armv7"
    ALERT_ARCH="linux-armv7"
elif [[ "$ARCH" == "x86_64" ]]; then
    PROM_ARCH="linux-amd64"
    NODE_ARCH="linux-amd64"
    ALERT_ARCH="linux-amd64"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

# 2. versions (hardcoded for stability, but could be dynamic)
PROM_VER="2.53.0"
NODE_VER="1.8.1"
ALERT_VER="0.27.0"

# 3. Create Users
useradd --no-create-home --shell /bin/false prometheus || true
useradd --no-create-home --shell /bin/false node_exporter || true
useradd --no-create-home --shell /bin/false alertmanager || true

# 4. Install Node Exporter
if [ ! -f /usr/local/bin/node_exporter ]; then
    echo "Installing Node Exporter..."
    wget https://github.com/prometheus/node_exporter/releases/download/v${NODE_VER}/node_exporter-${NODE_VER}.${NODE_ARCH}.tar.gz
    tar xvf node_exporter-${NODE_VER}.${NODE_ARCH}.tar.gz
    cp node_exporter-${NODE_VER}.${NODE_ARCH}/node_exporter /usr/local/bin/
    rm -rf node_exporter*
fi
cp "$SCRIPT_DIR/systemd/node_exporter.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now node_exporter

# 5. Install Prometheus
if [ ! -f /usr/local/bin/prometheus ]; then
    echo "Installing Prometheus..."
    wget https://github.com/prometheus/prometheus/releases/download/v${PROM_VER}/prometheus-${PROM_VER}.${PROM_ARCH}.tar.gz
    tar xvf prometheus-${PROM_VER}.${PROM_ARCH}.tar.gz
    cp prometheus-${PROM_VER}.${PROM_ARCH}/prometheus /usr/local/bin/
    cp prometheus-${PROM_VER}.${PROM_ARCH}/promtool /usr/local/bin/
    
    mkdir -p /etc/prometheus /var/lib/prometheus
    cp -r prometheus-${PROM_VER}.${PROM_ARCH}/consoles /etc/prometheus
    cp -r prometheus-${PROM_VER}.${PROM_ARCH}/console_libraries /etc/prometheus
    rm -rf prometheus*
fi

# Configure Prometheus
cp "$SCRIPT_DIR/config/prometheus.yml" /etc/prometheus/prometheus.yml
cp "$SCRIPT_DIR/config/alert_rules.yml" /etc/prometheus/alert_rules.yml
chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
cp "$SCRIPT_DIR/systemd/prometheus.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now prometheus

# 6. Install Alertmanager
if [ ! -f /usr/local/bin/alertmanager ]; then
    echo "Installing Alertmanager..."
    wget https://github.com/prometheus/alertmanager/releases/download/v${ALERT_VER}/alertmanager-${ALERT_VER}.${ALERT_ARCH}.tar.gz
    tar xvf alertmanager-${ALERT_VER}.${ALERT_ARCH}.tar.gz
    cp alertmanager-${ALERT_VER}.${ALERT_ARCH}/alertmanager /usr/local/bin/
    cp alertmanager-${ALERT_VER}.${ALERT_ARCH}/amtool /usr/local/bin/
    
    mkdir -p /etc/alertmanager /var/lib/alertmanager
    rm -rf alertmanager*
fi

# Configure Alertmanager
echo "Configuring Alertmanager..."

# Logic:
# 1. If vars provided -> Overwrite with template + inject.
# 2. If NO vars provided -> Check if existing valid config.
#    a. If valid -> Do nothing (Keep existing).
#    b. If invalid/missing -> Overwrite with blackhole default.

echo "Debug: Checking Telegram Variables..."
if [ -n "$TELEGRAM_ADMIN_TOKEN" ] && [ -n "$TELEGRAM_ADMIN_CHAT_ID" ]; then
    echo "Updating Alertmanager with Admin Bot credentials..."
    cp "$SCRIPT_DIR/config/alertmanager.yml" /etc/alertmanager/alertmanager.yml
    sed -i "s/PLACEHOLDER_TOKEN/$TELEGRAM_ADMIN_TOKEN/g" /etc/alertmanager/alertmanager.yml
    sed -i "s/PLACEHOLDER_CHAT_ID/$TELEGRAM_ADMIN_CHAT_ID/g" /etc/alertmanager/alertmanager.yml
    # FORCE RESTART to pick up new template
    systemctl restart alertmanager
elif [ -f /etc/alertmanager/alertmanager.yml ] && grep -q "bot_token" /etc/alertmanager/alertmanager.yml; then
    echo "Existing Telegram configuration detected. Keeping it."
else
    echo "No Telegram credentials provided. Configuring Alertmanager with default minimal config."
    # Create a minimal valid config to prevent crash
    cat <<EOF > /etc/alertmanager/alertmanager.yml
global:
  resolve_timeout: 5m
route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'web.hook'
receivers:
- name: 'web.hook'
  webhook_configs:
  - url: 'http://127.0.0.1:5001/'
EOF
fi

chown -R alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager
cp "$SCRIPT_DIR/systemd/alertmanager.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now alertmanager

# 7. Install Grafana
# 7. Install Grafana
if ! command -v grafana-server >/dev/null; then
    echo "Installing Grafana..."
    apt-get install -y apt-transport-https software-properties-common wget libfontconfig1
    
    mkdir -p /etc/apt/keyrings/
    
    echo "Downloading Grafana GPG key..."
    rm -f /tmp/grafana.key
    wget -q -O /tmp/grafana.key https://apt.grafana.com/gpg.key
    
    # Verify key download
    if [ ! -s /tmp/grafana.key ]; then
        echo "Error: Failed to download Grafana GPG key."
        exit 1
    fi

    cat /tmp/grafana.key | gpg --dearmor | tee /etc/apt/keyrings/grafana.gpg > /dev/null
    
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" | tee /etc/apt/sources.list.d/grafana.list
    
    echo "Updating apt cache..."
    apt-get update
    
    echo "Installing Grafana package..."
    apt-get install -y grafana
fi


# Configure Grafana Admin User (fresh install override)
if [ -n "$GRAFANA_ADMIN_USER" ] && [ "$GRAFANA_ADMIN_USER" != "admin" ]; then
    echo "Configuring Grafana admin user to: $GRAFANA_ADMIN_USER"
    mkdir -p /etc/grafana
    if [ -f /etc/grafana/grafana.ini ]; then
        sed -i "s/^;admin_user = .*/admin_user = $GRAFANA_ADMIN_USER/" /etc/grafana/grafana.ini
        sed -i "s/^admin_user = .*/admin_user = $GRAFANA_ADMIN_USER/" /etc/grafana/grafana.ini
    fi
fi

# Ensure Grafana binds to all interfaces (0.0.0.0)
if [ -f /etc/grafana/grafana.ini ]; then
    echo "Ensuring Grafana binds to 0.0.0.0..."
    sed -i 's/^;http_addr =.*/http_addr = 0.0.0.0/' /etc/grafana/grafana.ini
    sed -i 's/^http_addr =.*/http_addr = 0.0.0.0/' /etc/grafana/grafana.ini
fi

# Configure Grafana Provisioning (Dashboards & Datasources)
echo "Configuring Grafana Provisioning..."
mkdir -p /etc/grafana/provisioning/dashboards
mkdir -p /etc/grafana/provisioning/datasources

cp "$SCRIPT_DIR/config/grafana_provisioning_dashboards.yaml" /etc/grafana/provisioning/dashboards/default.yaml
cp "$SCRIPT_DIR/config/grafana_provisioning_datasources.yaml" /etc/grafana/provisioning/datasources/prometheus.yaml
cp "$SCRIPT_DIR/config/node_exporter_dashboard.json" /etc/grafana/provisioning/dashboards/node_exporter.json

# Ensure permissions
chown -R root:grafana /etc/grafana/provisioning
chmod -R 640 /etc/grafana/provisioning/dashboards/*
chmod -R 640 /etc/grafana/provisioning/datasources/*

# Ensure service is stopped to modify DB/Reset Pass safely
systemctl stop grafana-server

# Reset admin password
if [ -n "$GRAFANA_ADMIN_PASS" ]; then
    echo "Setting Grafana admin password..."
    # --homepath is required. --config is good practice for some versions.
    grafana-cli admin reset-admin-password "$GRAFANA_ADMIN_PASS" --homepath "/usr/share/grafana" --config "/etc/grafana/grafana.ini" || echo "Warning: Password reset failed."
fi

systemctl daemon-reload
systemctl unmask grafana-server || true
systemctl enable grafana-server

# Fix permissions for Grafana DB (Critical for startups after reset)
echo "Fixing Grafana permissions..."
chown -R grafana:grafana /var/lib/grafana
chmod -R 750 /var/lib/grafana

systemctl restart grafana-server

echo "--- Monitoring Stack Setup Complete ---"
