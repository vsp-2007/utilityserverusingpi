#!/bin/bash

# ANSI Color Codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Helper Functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check for Root
if [ "$EUID" -ne 0 ]; then
  log_error "Please run as root (sudo ./install.sh)"
  exit 1
fi

# FX: Fix Windows Line Endings automatically
sed -i 's/\r$//' setup.conf 2>/dev/null
sed -i 's/\r$//' setup.conf.example 2>/dev/null
sed -i 's/\r$//' scripts/*.sh 2>/dev/null
sed -i 's/\r$//' config/* 2>/dev/null

# Directory of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/setup.conf"
export CONFIG_FILE

# Load or Initialize Configuration
if [ ! -f "$CONFIG_FILE" ]; then
    log_warn "Configuration file not found."
    read -p "Create from example? [Y/n] " create_conf
    create_conf=${create_conf:-Y}
    if [[ $create_conf =~ ^[Yy]$ ]]; then
        cp "$SCRIPT_DIR/setup.conf.example" "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE" # Secure file (Root read/write only)
        log_info "Created setup.conf. Please configure variables if you wish to run unattended."
        log_info "Proceeding with interactive setup..."
    else
        log_error "Cannot proceed without configuration structure."
        exit 1
    fi
fi

# Load Config
source "$CONFIG_FILE"

# FX: Sanitize Config (Trim whitespace from tokens)
sanitize_var() {
    local var_name=$1
    local current_val="${!var_name}"
    if [ -n "$current_val" ]; then
        # Trim leading/trailing whitespace
        local clean_val=$(echo "$current_val" | xargs)
        if [ "$current_val" != "$clean_val" ]; then
            eval "$var_name=\"$clean_val\""
            export $var_name
            # Update file on disk
            sed -i "s|^$var_name=.*|$var_name=\"$clean_val\"|" "$CONFIG_FILE"
        fi
    fi
}
# Apply to critical tokens that might have copy-paste whitespace
sanitize_var "TELEGRAM_ADMIN_TOKEN"
sanitize_var "TELEGRAM_USER_TOKEN"
sanitize_var "TAILSCALE_AUTH_KEY"

# Function to prompt for missing variables
ensure_var() {
    local var_name=$1
    local prompt_text=$2
    local is_secret=$3
    
    if [ -z "${!var_name}" ]; then
        if [ "$is_secret" == "true" ]; then
            read -sp "$prompt_text: " input_val
            echo
        else
            read -p "$prompt_text: " input_val
        fi
        
        # Update variable in memory and export to environment
        eval "$var_name=\"$input_val\""
        export $var_name
        
        # Ask to save to file
        read -p "Save to setup.conf? [Y/n] " save_var
        save_var=${save_var:-Y}
        if [[ $save_var =~ ^[Yy]$ ]]; then
             sed -i "s|^$var_name=.*|$var_name=\"$input_val\"|" "$CONFIG_FILE"
        fi
    fi
}

# --- Main Menu ---
echo "========================================="
echo " Raspberry Pi All-in-One Installer"
echo "========================================="

# Ensure credentials for selected modules are present before running
check_creds() {
    echo "Checking configuration..."
    
    # Always check basics
    ensure_var "PI_USER" "Enter System Username" "false"
    
    # Check Monitoring Creds if running 4 or A
    if [[ "$selection" == "4" ]] || [[ "$selection" =~ ^[Aa] ]]; then
        GRAFANA_ADMIN_USER="admin"
        
        # Grafana Password Handling
        echo
        read -p "Do you want to set/reset the Grafana Admin Password? [Y/n] " reset_graf
        reset_graf=${reset_graf:-Y}
        
        if [[ $reset_graf =~ ^[Yy]$ ]]; then
             unset GRAFANA_ADMIN_PASS # Force ensure_var to prompt
             ensure_var "GRAFANA_ADMIN_PASS" "Enter New Grafana Admin Password (MUST be >= 8 chars)" "true"
        else
             echo "Keeping existing Grafana password (if set)."
        fi
        
        if [ "$skip_tg_prompt" != "true" ]; then
            # (Implicitly handling alerts via the Bot section below)
            true 
        fi
    fi

    # Check Telegram Bots if running 4, 7, or A
    if [[ "$selection" == "4" ]] || [[ "$selection" == "7" ]] || [[ "$selection" =~ ^[Aa] ]]; then
        echo
        echo "--- Telegram Bot Setup ---"
        
        # Admin Bot
        # 1. Attempt to recover from existing system files (Service or Alertmanager)
        # 1. Attempt to recover from existing system files (Service or Alertmanager)
        # Check active Systemd Service (Checking this first/independently to get User Token too)
        if [ -f /etc/systemd/system/telegram_bot.service ]; then
             EXISTING_ENV=$(grep "^EnvironmentFile=" /etc/systemd/system/telegram_bot.service | cut -d= -f2)
             if [ -n "$EXISTING_ENV" ] && [ -f "$EXISTING_ENV" ]; then
                  # Only load if it's NOT the same file we are currently using (avoid double read)
                  if [ "$EXISTING_ENV" != "$CONFIG_FILE" ]; then
                      # Recover whatever is missing
                      REC_ADMIN_TOKEN=$(grep "^TELEGRAM_ADMIN_TOKEN=" "$EXISTING_ENV" | cut -d= -f2 | tr -d '"' | xargs)
                      REC_ADMIN_CHAT=$(grep "^TELEGRAM_ADMIN_CHAT_ID=" "$EXISTING_ENV" | cut -d= -f2 | tr -d '"' | xargs)
                      REC_USER_TOKEN=$(grep "^TELEGRAM_USER_TOKEN=" "$EXISTING_ENV" | cut -d= -f2 | tr -d '"' | xargs)
                      
                      if [ -z "$TELEGRAM_ADMIN_TOKEN" ] && [ -n "$REC_ADMIN_TOKEN" ]; then
                           echo "Found active config at $EXISTING_ENV. Recovering Admin..."
                           TELEGRAM_ADMIN_TOKEN="$REC_ADMIN_TOKEN"
                           TELEGRAM_ADMIN_CHAT_ID="$REC_ADMIN_CHAT"
                      fi
                      
                      if [ -z "$TELEGRAM_USER_TOKEN" ] && [ -n "$REC_USER_TOKEN" ]; then
                           echo "Found active config at $EXISTING_ENV. Recovering User Bot..."
                           TELEGRAM_USER_TOKEN="$REC_USER_TOKEN"
                      fi
                  fi
             fi
        fi
        
        if [ -z "$TELEGRAM_ADMIN_TOKEN" ]; then
             # Fallback: Check Persistent Backup (for User Token mainly, but also Admin)
             if [ -z "$TELEGRAM_ADMIN_TOKEN" ] || [ -z "$TELEGRAM_USER_TOKEN" ]; then
                 if [ -f /etc/pi-server-credentials.conf ]; then
                      source /etc/pi-server-credentials.conf
                      # We just sourced them, so if they were there, they are set now.
                      # We can log it.
                      if [ -n "$TELEGRAM_ADMIN_TOKEN" ]; then
                          echo "Recovered Admin Token from persistent backup."
                      fi
                      if [ -n "$TELEGRAM_USER_TOKEN" ]; then
                          echo "Recovered User Token from persistent backup."
                      fi
                 fi
             fi
             
             # Fallback: Check Alertmanager Config
             if [ -z "$TELEGRAM_ADMIN_TOKEN" ] && [ -f /etc/alertmanager/alertmanager.yml ]; then
                  # Parsing: Look for 'bot_token: value', strip 'bot_token:', whitespace, quotes
                  REC_AM_TOKEN=$(grep "bot_token:" /etc/alertmanager/alertmanager.yml | sed 's/.*bot_token:[[:space:]]*//;s/["'\'']//g')
                  REC_AM_CHAT=$(grep "chat_id:" /etc/alertmanager/alertmanager.yml | sed 's/.*chat_id:[[:space:]]*//;s/["'\'']//g')
                  
                  if [ -n "$REC_AM_TOKEN" ]; then
                       echo "Found Admin Credentials in Alertmanager."
                       TELEGRAM_ADMIN_TOKEN="$REC_AM_TOKEN"
                       TELEGRAM_ADMIN_CHAT_ID="$REC_AM_CHAT"
                  fi
             fi
        fi

        if [ -n "$TELEGRAM_ADMIN_TOKEN" ] && [ -n "$TELEGRAM_ADMIN_CHAT_ID" ]; then
            echo "Current Admin Bot config found (System/Config):"
            echo "   Token: ...${TELEGRAM_ADMIN_TOKEN: -5}"
            echo "   Chat ID: $TELEGRAM_ADMIN_CHAT_ID"
            read -p "Use these existing Admin Bot credentials? [Y/n] " keep_admin_tg
            keep_admin_tg=${keep_admin_tg:-Y}
            if [[ ! $keep_admin_tg =~ ^[Yy]$ ]]; then
                unset TELEGRAM_ADMIN_TOKEN
                unset TELEGRAM_ADMIN_CHAT_ID
            else
                grep -q "^TELEGRAM_ADMIN_TOKEN=" "$CONFIG_FILE" && sed -i "s|^TELEGRAM_ADMIN_TOKEN=.*|TELEGRAM_ADMIN_TOKEN=\"$TELEGRAM_ADMIN_TOKEN\"|" "$CONFIG_FILE" || echo "TELEGRAM_ADMIN_TOKEN=\"$TELEGRAM_ADMIN_TOKEN\"" >> "$CONFIG_FILE"
                grep -q "^TELEGRAM_ADMIN_CHAT_ID=" "$CONFIG_FILE" && sed -i "s|^TELEGRAM_ADMIN_CHAT_ID=.*|TELEGRAM_ADMIN_CHAT_ID=\"$TELEGRAM_ADMIN_CHAT_ID\"|" "$CONFIG_FILE" || echo "TELEGRAM_ADMIN_CHAT_ID=\"$TELEGRAM_ADMIN_CHAT_ID\"" >> "$CONFIG_FILE"
            fi
        fi
        ensure_var "TELEGRAM_ADMIN_TOKEN" "Enter Admin Bot Token" "false"
        ensure_var "TELEGRAM_ADMIN_CHAT_ID" "Enter Admin Chat ID (User ID)" "false"

        # User Bot
        if [ -n "$TELEGRAM_USER_TOKEN" ]; then
            echo "Current User Bot Token found in setup.conf:"
            echo "   Token: ...${TELEGRAM_USER_TOKEN: -5}"
            read -p "Use this existing User Bot token? [Y/n] " keep_user_tg
            keep_user_tg=${keep_user_tg:-Y}
            if [[ ! $keep_user_tg =~ ^[Yy]$ ]]; then
                unset TELEGRAM_USER_TOKEN
            else
                grep -q "^TELEGRAM_USER_TOKEN=" "$CONFIG_FILE" && sed -i "s|^TELEGRAM_USER_TOKEN=.*|TELEGRAM_USER_TOKEN=\"$TELEGRAM_USER_TOKEN\"|" "$CONFIG_FILE" || echo "TELEGRAM_USER_TOKEN=\"$TELEGRAM_USER_TOKEN\"" >> "$CONFIG_FILE"
            fi
        fi
        ensure_var "TELEGRAM_USER_TOKEN" "Enter User Bot Token (Group Bot)" "false"
    fi
    
    # Check Samba if running 5 or A
    if [[ "$selection" == "5" ]] || [[ "$selection" =~ ^[Aa] ]]; then
         ensure_var "SMB_USER" "Enter Samba Username" "false"
         # SMB_PASS removed from upfront prompt
         
         # Webmin
         read -p "Install Webmin (Web UI for System/Samba)? [Y/n] " install_webmin
         install_webmin=${install_webmin:-Y}
         if [[ $install_webmin =~ ^[Yy]$ ]]; then
             export webmin_enabled="true"
             # Save to config if desired, or just export
             if grep -q "webmin_enabled=" "$CONFIG_FILE"; then
                 sed -i "s/webmin_enabled=.*/webmin_enabled=true/" "$CONFIG_FILE"
             else
                 echo "webmin_enabled=true" >> "$CONFIG_FILE"
             fi
         else
             export webmin_enabled="false"
         fi
    fi

    # Create System-Wide Backup of Credentials (for recovery if folder is deleted)
    if [ -n "$TELEGRAM_ADMIN_TOKEN" ] || [ -n "$TELEGRAM_USER_TOKEN" ] || [ -n "$SMB_USER" ]; then
        echo "# Pi Server persistent credentials backup" > /etc/pi-server-credentials.conf
        chmod 600 /etc/pi-server-credentials.conf
        [ -n "$TELEGRAM_ADMIN_TOKEN" ] && echo "TELEGRAM_ADMIN_TOKEN=\"$TELEGRAM_ADMIN_TOKEN\"" >> /etc/pi-server-credentials.conf
        [ -n "$TELEGRAM_ADMIN_CHAT_ID" ] && echo "TELEGRAM_ADMIN_CHAT_ID=\"$TELEGRAM_ADMIN_CHAT_ID\"" >> /etc/pi-server-credentials.conf
        [ -n "$TELEGRAM_USER_TOKEN" ] && echo "TELEGRAM_USER_TOKEN=\"$TELEGRAM_USER_TOKEN\"" >> /etc/pi-server-credentials.conf
        [ -n "$SMB_USER" ] && echo "SMB_USER=\"$SMB_USER\"" >> /etc/pi-server-credentials.conf
        echo "✅ Credentials backed up to /etc/pi-server-credentials.conf for future recovery."
    fi

    # Check Network if running 2 or A
    if [[ "$selection" == "2" ]] || [[ "$selection" =~ ^[Aa] ]]; then
         # Only if not authenticated
          if ! command -v tailscale >/dev/null || ! tailscale status >/dev/null 2>&1; then
             read -p "Do you have a Tailscale Auth Key? (Press Enter to skip/login interactive): " ts_key
             if [ -n "$ts_key" ]; then
                 TAILSCALE_AUTH_KEY="$ts_key"
             fi
          fi
    fi
}

echo "Select modules to install:"
echo "1) System Basics (Update, User, SSH, Tools)"
echo "2) Network (Tailscale, Static IP Helper)"
echo "3) Pi-hole (Ad Blocking)"
echo "4) Monitoring Stack (Prometheus, Grafana, Alertmanager)"
echo "5) File Sharing (Samba, Webmin)"
echo "6) Utilities (Status Report Script)"
echo "7) Telegram Bot (Interactive Control)"

LOCAL_INST="" ; [ -f "/opt/localsend/localsend_app" ] || [ -f "/usr/share/applications/localsend_app.desktop" ] && LOCAL_INST=" [Installed]"

NGINX_INST="" ; command -v nginx >/dev/null 2>&1 && NGINX_INST=" [Installed]"
COCKPIT_INST="" ; [ -d "/etc/cockpit" ] && COCKPIT_INST=" [Installed]"

echo "8) Localsend (File Sharing App)$LOCAL_INST"
echo "9) Stirling-PDF (PDF Tools)"
echo "10) Nginx Reverse Proxy (Domain Access)$NGINX_INST"
echo "11) Cockpit (Web-based Administration)$COCKPIT_INST"
echo "A) Install Everything"
echo "Q) Quit"

read -p "Enter selection [A]: " selection
selection=${selection:-A}

if [[ ! "$selection" =~ ^[Qq] ]]; then
    check_creds
fi

execute_script() {
    local script_name=$1
    local script_path="$SCRIPT_DIR/scripts/$script_name"
    if [ -f "$script_path" ]; then
        log_info "Executing $script_name..."
        chmod +x "$script_path"
        # Export all variables to sub-shell
        set -a
        # source "$CONFIG_FILE"  <-- REMOVED to prevent overwriting in-memory variables
        set +a
        "$script_path"
        if [ $? -eq 0 ]; then
            log_info "$script_name completed successfully."
        else
            log_error "$script_name failed."
            exit 1 # Optional: stop on error
        fi
    else
        log_error "Script $script_name not found!"
    fi
}

case $selection in
    1) execute_script "00-system.sh" ;;
    2) execute_script "01-network.sh" ;;
    3) execute_script "02-pihole.sh" ;;
    4) execute_script "03-monitoring.sh" ;;
    5) execute_script "04-samba.sh" ;;
    6) execute_script "05-utils.sh" ;;
    7) execute_script "06-telegram-bot.sh" ;;
    8) execute_script "07-localsend.sh" ;;

    9) execute_script "08-stirling-pdf.sh" ;;
    10) execute_script "09-reverse-proxy.sh" ;;
    11) execute_script "10-cockpit.sh" ;;
    [Aa]*)
        execute_script "00-system.sh"
        execute_script "01-network.sh"
        execute_script "02-pihole.sh"
        execute_script "03-monitoring.sh"
        execute_script "04-samba.sh"
        execute_script "05-utils.sh"
        execute_script "06-telegram-bot.sh"
        execute_script "07-localsend.sh"

        execute_script "08-stirling-pdf.sh"
        execute_script "09-reverse-proxy.sh"
        execute_script "10-cockpit.sh"
        ;;
    [Qq]*) exit 0 ;;
    *) echo "Invalid selection"; exit 1 ;;
esac

# Summary Function
show_summary() {
    local IP=$(hostname -I | awk '{print $1}')
    echo
    echo "========================================================="
    echo "                  INSTALLATION SUMMARY                   "
    echo "========================================================="
    echo "Device IP: $IP"
    echo
    
    # System Info
    if [[ "$selection" =~ [1Aa] ]]; then
         echo "## System"
         echo "   - SSH:           ssh $PI_USER@$IP"
         echo "   - VNC:           $IP:5900"
         echo
    fi

    # Pi-hole
    if [[ "$selection" =~ [3Aa] ]]; then
        echo "## Pi-hole"
        echo "   - URL:           http://$IP/admin"
        if [ -n "$PIHOLE_PASSWORD" ]; then
             echo "   - Password:      $PIHOLE_PASSWORD"
        else
             echo "   - Password:      (Run 'pihole -a -p' to set if unknown)"
        fi
        echo "   - Config:        /etc/pihole"
        echo
    fi

    # Monitoring
    if [[ "$selection" =~ [4Aa] ]]; then
        echo "## Monitoring Stack"
        echo "   - Prometheus:    http://$IP:9090"
        echo "     (Config: /etc/prometheus/prometheus.yml)"
        echo "   - Alertmanager:  http://$IP:9093"
        echo "     (Config: /etc/alertmanager/alertmanager.yml)"
        echo "   - Node Exporter: http://$IP:9100/metrics"
        echo "     (System Metrics: CPU, Mem, Disk)"
        echo "   - Grafana:       http://$IP:3000"
        echo "     - User:        ${GRAFANA_ADMIN_USER:-admin}"
        echo "     - Password:    ${GRAFANA_ADMIN_PASS:-admin}"
        echo
    fi
    
    # Samba/Webmin
    if [[ "$selection" =~ [5Aa] ]]; then
        echo "## File Sharing"
        echo "   - Webmin:        https://$IP:10000"
        echo "     - Login:       $PI_USER (System Password)"
        echo
        echo -e "   - ${YELLOW}${BOLD}GUIDE:       file://$SCRIPT_DIR/docs/webmin_guide.html${NC}"
        echo "     (Open this link in your browser for the sharing manual)"
        echo
        echo "   - Samba Share:   \\\\$IP\\share"
        echo "     - User:        ${SMB_USER:-$PI_USER}"
        echo "     - Password:    (As configured)"
        echo "     - Config:      /etc/samba/smb.conf"
        echo "     - Path:        /home/${SMB_USER:-$PI_USER}/share"
        echo
    fi

    # Utilities
    if [[ "$selection" =~ [6Aa] ]] || [ "$selection" == "6" ]; then
        echo "## Utilities & Reports"
        echo "   - Status Script:  /usr/local/bin/send_report.sh"
        echo "   - Alert Report:   /usr/local/bin/send_report_to_alertmanager.sh"
        echo "   - Schedule:       Reboot & Daily (08:00)"
        echo
    fi

    # Telegram Bot
    if [[ "$selection" =~ [7Aa] ]]; then
        echo "## Telegram Bot"
        echo "   - Service:       telegram_bot.service"
        echo "   - Admin Bot:     Private Control"
        echo "   - User Bot:      Public Status Reporting"
        echo
    fi
    
    # Localsend
    if [[ "$selection" =~ [8Aa] ]]; then
        echo "## Localsend"
        echo "   - App installed."
        echo "   - Desktop Shortcut: Created"
        echo "   - Port: 53317 (Allowed)"
        echo
    fi


    # Stirling-PDF
    if [[ "$selection" =~ [9Aa] ]]; then
        echo "## Stirling-PDF"
        echo "   - URL:           http://$IP:8080"
        echo "   - Service:       stirling-pdf"
        echo "   - Config:        /opt/Stirling-PDF"
        echo
    fi
    
    # Nginx Proxy
    if [[ "$selection" == "10" ]] || [[ "$selection" =~ [Aa] ]]; then
        echo "## Reverse Proxy (Domains)"
        echo "   - Dashboard:     http://dashboard.home (Cockpit)"
        echo "   - Pi-hole:       http://pi.home"
        echo "   - PDF Tools:     http://pdf.home"
        echo "   - Grafana:       http://grafana.home"
        echo "   - Prometheus:    http://prometheus.home"
        echo "   * Setup DNS:     http://$IP:8081/admin/dns_records.php"
        echo
    fi


    
    # Cockpit
    if [[ "$selection" == "11" ]] || [[ "$selection" =~ [Aa] ]]; then
        echo "## Cockpit (System Administration)"
        echo "   - URL:           https://$IP:9091"
        echo "   - Login:         Use Pi System Credentials"
        echo
    fi
    
    echo "========================================================="
}

# Reload config to capture any updates from subscripts (e.g. SMB_USER)
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

show_summary
echo -e "${GREEN}Installation Sequence Complete!${NC}"
