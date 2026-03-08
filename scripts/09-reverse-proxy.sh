#!/bin/bash
set -e
echo "--- Setting up Nginx Reverse Proxy ---"

# 1. Install Nginx
echo "Installing Nginx..."
apt-get update
# Suppress dialogs
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx

# 2. Resolve Port 80 Conflict (Pi-hole FTL Webserver)
echo "Resolving Port 80 usage..."

# Stop services to free up port 80
systemctl stop pihole-FTL || true
systemctl stop nginx || true
systemctl stop lighttpd || true

# Check for Pi-hole v6 Config (TOML)
TOML_CONF="/etc/pihole/pihole.toml"
FTL_CONF="/etc/pihole/pihole-FTL.conf"

if [ -f "$TOML_CONF" ]; then
    echo "Found Pi-hole v6 (TOML). Updating webserver port..."
    # Naive TOML update: Ensure [webserver] section exists check is hard with just sed.
    # Assuming standard structure or forcing it.
    
    # If using newer pihole cli?
    # Try using pihole-FTL command if available to set config?
    # But direct edit is safer if FTL is stopped.
    
    # 1. Check if 'port =' exists under [webserver] (Complex with sed/grep multiline)
    # Simpler approach: Check if we can use pihole-FTL --config
    
    if command -v pihole-FTL >/dev/null; then
        echo "Using pihole-FTL CLI to set port..."
        # v6 syntax might be:
        pihole-FTL --config webserver.port 8081
        echo "✅ Pi-hole v6 Web Port set to 8081 via CLI."
    else
        # Fallback SED: This is risky on TOML but we try to match `port = 80` inside webserver block roughly
        # Or just tell user to do it if CLI fails.
        echo "⚠️ pihole-FTL CLI not found. Attempting manual TOML edit..."
        # Verify if [webserver] exists
        if grep -q "\[webserver\]" "$TOML_CONF"; then
             # Replace sensitive port=80 with port=8081
             sed -i 's/port = 80$/port = 8081/' "$TOML_CONF"
             sed -i 's/port = "80"/port = 8081/' "$TOML_CONF"
        else
             echo "" >> "$TOML_CONF"
             echo "[webserver]" >> "$TOML_CONF"
             echo "  port = 8081" >> "$TOML_CONF"
        fi
    fi

elif [ -f "$FTL_CONF" ]; then
    echo "Found Pi-hole v5 config. Changing embedded web server port to 8081..."
    
    # Check if FTLCONF_webserver_port is already set
    if grep -q "FTLCONF_webserver_port=" "$FTL_CONF"; then
        sed -i 's/^FTLCONF_webserver_port=.*/FTLCONF_webserver_port=8081/' "$FTL_CONF"
    else
        echo "FTLCONF_webserver_port=8081" >> "$FTL_CONF"
    fi
    echo "✅ Pi-hole FTL Web Port set to 8081."
    
else
    # Fallback to Lighttpd logic ONLY if FTL config is missing (unlikely for modern Pi-hole)
    echo "⚠️ Pi-hole FTL config not found. Checking Lighttpd..."
    if [ -f /etc/lighttpd/lighttpd.conf ]; then
        sed -i -E 's/^server.port\s*=\s*80/server.port                 = 8081/g' /etc/lighttpd/lighttpd.conf
        if [ -f /etc/lighttpd/external.conf ]; then
             sed -i -E 's/server.port\s*=\s*80/server.port = 8081/g' /etc/lighttpd/external.conf
        fi
        echo "✅ Lighttpd moved to port 8081."
        systemctl stop lighttpd
    else
        echo "ℹ️ No conflicting Pi-hole web server config found. Proceeding..."
    fi
fi

# 3. Configure Nginx
echo "Creating Nginx Configuration..."

# Remove default if exists to avoid conflicts
rm -f /etc/nginx/sites-enabled/default

# Define the Proxy Configuration
cat <<EOF > /etc/nginx/sites-available/reverse-proxy.conf
# Default catch-all
server {
    listen 80 default_server;
    server_name _;
    
    location / {
        return 200 '<html><body><h1>Raspberry Pi Gateway</h1><p>Services are running.</p><ul><li><a href="http://dashboard.home">Dashboard (Cockpit)</a></li><li><a href="http://pi.home">Pi-hole</a></li><li><a href="http://pdf.home">Stirling PDF</a></li><li><a href="http://grafana.home">Grafana</a></li></ul></body></html>';
        add_header Content-Type text/html;
    }
}

# Cockpit (dashboard.home)
server {
    listen 80;
    server_name dashboard.home;

    location / {
        proxy_pass http://localhost:9091;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

# 1. Stirling-PDF (pdf.home)
server {
    listen 80;
    server_name pdf.home;

    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

# 2. Pi-hole (pi.home)
server {
    listen 80;
    server_name pi.home;

    # Redirect root to admin for convenience
    location = / {
        return 301 http://pi.home/admin;
    }

    location / {
        proxy_pass http://localhost:8081;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}

# 3. Grafana (grafana.home)
server {
    listen 80;
    server_name grafana.home;

    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}

# 4. Prometheus (prometheus.home)
server {
    listen 80;
    server_name prometheus.home;

    location / {
        proxy_pass http://localhost:9090;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

# Enable Site
ln -sf /etc/nginx/sites-available/reverse-proxy.conf /etc/nginx/sites-enabled/

# Test and Restart
echo "Verifying Nginx config..."
nginx -t

echo "Restarting Services..."
# Restart Nginx (Port 80)
systemctl restart nginx

# Start Lighttpd (Port 8081)
if [ -f /etc/lighttpd/lighttpd.conf ]; then
    systemctl restart lighttpd
fi

# Restart Pi-hole FTL (Port 53)
# It might complain about Port 80 being taken (by Nginx), but harmless for DNS.
systemctl restart pihole-FTL

echo "✅ Nginx & Pi-hole Configured successfully."
echo "-----------------------------------------------------"
echo "IMPORTANT: You must now configure Local DNS in Pi-hole:"
echo "1. Go to http://<YOUR_PI_IP>:8081/admin/dns_records.php"
echo "2. Add the following records pointing to YOUR PI'S IP address:"
echo "   - dashboard.home"
echo "   - pdf.home"
echo "   - pi.home"
echo "   - grafana.home"
echo "   - prometheus.home"
echo "-----------------------------------------------------"
