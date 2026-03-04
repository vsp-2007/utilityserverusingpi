#!/bin/bash
echo "--- Starting File Sharing Setup ---"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 1. Install Samba
if command -v smbd >/dev/null; then
    echo "Samba is already installed."
    read -p "Do you want to reinstall/reconfigure Samba shares? [y/N] " reconfig_samba
    if [[ ! "$reconfig_samba" =~ ^[Yy]$ ]]; then
        echo "Skipping Samba installation/configuration."
        # Jump to Webmin or Exit?
        # The script continues linearly. We should probably wrap the config part or exit if just this script.
        # But Webmin is also in this script.
        SKIP_SAMBA_CONFIG=true
    fi
else
    echo "Installing Samba..."
    apt-get install -y samba samba-common-bin
fi

if [ "$SKIP_SAMBA_CONFIG" != "true" ]; then

# 2. Configure Samba User
# Ensure SMB_USER is known
if [ -z "$SMB_USER" ]; then
    read -p "Enter Samba Username: " SMB_USER
    
    # Save to setup.conf for parent script summary
    CONF_FILE="$SCRIPT_DIR/setup.conf"
    if [ -f "$CONF_FILE" ]; then
        if grep -q "^SMB_USER=" "$CONF_FILE"; then
            sed -i "s/^SMB_USER=.*/SMB_USER=\"$SMB_USER\"/" "$CONF_FILE"
        else
            echo "SMB_USER=\"$SMB_USER\"" >> "$CONF_FILE"
        fi
    fi
fi

# Check if system user exists
NEW_USER_CREATED="false"
if ! id "$SMB_USER" &>/dev/null; then
    echo "User $SMB_USER does not exist in system."
    echo "How would you like to create this user?"
    echo "1) Standard User (Can login to Desktop/SSH)"
    echo "2) Share-Only User (No shell, No home, Safer for file sharing only)"
    read -p "Select option [1/2]: " user_type
    
    if [ "$user_type" == "2" ]; then
        echo "Creating Share-Only user (no login permission)..."
        # Fixed: using useradd flags (-M = no home, -s = shell)
        useradd -M -s /usr/sbin/nologin "$SMB_USER"
        
        echo "--------------------------------------------------"
        echo "Please set the Samba password for $SMB_USER."
        echo "--------------------------------------------------"
        # Use smbpasswd -a for standard interactive prompts (New SMB password: / Retype...)
        # This replaces the silent/script-oriented pdbedit -t
        smbpasswd -a "$SMB_USER"
        
    else
        echo "Creating Standard user..."
        useradd -m -s /bin/bash "$SMB_USER"
        echo "Please set system password:"
        passwd "$SMB_USER"
        
        # Add to Samba logic will handle the smbpassword below normally if not added here
        # But commonly we add them to samba right away or let the next block handle it.
        # Consistency: Let's let the next block handle it OR mark as created if we added it above?
        # Standard user usually needs separate samba add. Share user got added above via smbpasswd -a
    fi
    NEW_USER_CREATED="true"
fi

# Add to Samba (If not already added via pdbedit/smbpasswd above)
# Check if user is already in Samba
if pdbedit -L | grep -q "^$SMB_USER:"; then
    # Only verify/reset if we didn't JUST create them
    if [ "$NEW_USER_CREATED" != "true" ]; then
        echo "Samba user '$SMB_USER' already exists."
        read -p "Do you want to reset the Samba password for $SMB_USER? [y/N] " reset_smb_pass
        if [[ "$reset_smb_pass" =~ ^[Yy]$ ]]; then
            echo "Resetting Samba password..."
            smbpasswd -a "$SMB_USER"
        else
            echo "Skipping password reset."
        fi
    fi
else
    # New user not in Samba yet (and not added by pdbedit above if standard user)
    if [ -n "$SMB_PASS" ]; then
         (echo "$SMB_PASS"; echo "$SMB_PASS") | smbpasswd -s -a "$SMB_USER"
    else
        echo "--------------------------------------------------"
        echo "Please set Samba password for $SMB_USER:"
        echo "(Enter password twice)"
        echo "--------------------------------------------------"
        smbpasswd -a "$SMB_USER"
    fi
fi

# 3. Configure Shares
echo "Configuring smb.conf..."
mkdir -p /home/"$SMB_USER"/share
chown "$SMB_USER":"$SMB_USER" /home/"$SMB_USER"/share
chmod 770 /home/"$SMB_USER"/share

cp "$SCRIPT_DIR/config/smb.conf" /etc/samba/smb.conf
# Replace 'rebel' placeholder if user is different
sed -i "s/rebel/$SMB_USER/g" /etc/samba/smb.conf

service smbd restart
service nmbd restart
fi # End of SKIP_SAMBA_CONFIG

# 4. Install Webmin
if [ "$webmin_enabled" == "true" ]; then
    echo "Installing Webmin..."
    # Add Webmin repo
    echo "Installing Webmin..."
    
    # 1. Cleanup: Remove old Webmin entries from main sources.list AND sources.list.d to prevent duplicates
    if grep -q "webmin" /etc/apt/sources.list; then
        echo "Removing legacy Webmin entries from /etc/apt/sources.list..."
        sed -i '/webmin/d' /etc/apt/sources.list
    fi
    
    # Remove conflicting list files if they exist (to avoid "configured multiple times" warning)
    rm -f /etc/apt/sources.list.d/webmin.list
    rm -f /etc/apt/sources.list.d/webmin-stable.list

    # 2. Install dependencies (Modernized for Trixie/Bookworm)
    echo "Installing dependencies..."
    apt-get install -y perl libnet-ssleay-perl openssl libauthen-pam-perl libpam-runtime libio-pty-perl apt-show-versions python3 python-is-python3 gnupg curl

    # 3. Setup Webmin Repository (Official Script Method)
    # This solves the DSA1024 key issue by fetching the new signed keys automatically
    echo "Running Webmin Setup Script..."
    curl -o webmin-setup-repo.sh https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh
    sh webmin-setup-repo.sh --force
    rm webmin-setup-repo.sh

    # 4. Update & Install
    echo "Updating repositories..."
    apt-get update
    
    echo "Installing Webmin package..."
    apt-get install -y webmin
    
    # Ensure it's started
    systemctl enable webmin
    systemctl start webmin
    
    echo "Webmin installed. Access at https://<IP>:10000"

    # Install the Guide as HTML (Locally in project folder)
    # This avoids web server 404s and keeps it self-contained
    # SCRIPT_DIR is already the project root (see top of script)
    GUIDE_PATH="$SCRIPT_DIR/webmin_guide.html"

    echo "Generating Webmin Guide HTML..."
    cat << 'EOF' > "$GUIDE_PATH"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Webmin Samba Guide</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; background: #f4f4f9; }
        h1, h2, h3 { color: #2c3e50; }
        h1 { border-bottom: 2px solid #3498db; padding-bottom: 10px; }
        h2 { margin-top: 30px; border-bottom: 1px solid #ddd; padding-bottom: 5px; }
        .cheat-sheet { background: #fff; padding: 15px; border-radius: 8px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); margin-bottom: 20px; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { text-align: left; padding: 10px; border-bottom: 1px solid #eee; }
        th { background: #f8f9fa; }
        code { background: #e8f0fe; color: #000; padding: 2px 5px; border-radius: 3px; font-family: 'Courier New', Courier, monospace; }
        .scenario { background: #fff; padding: 20px; border-radius: 8px; box-shadow: 0 2px 5px rgba(0,0,0,0.05); margin-bottom: 20px; }
        .step { margin-bottom: 15px; }
        .note { background: #fff3cd; color: #856404; padding: 10px; border-radius: 5px; border-left: 5px solid #ffeeba; }
    </style>
</head>
<body>

<h1>Webmin Samba Share Guide</h1>
<p>This manual guides you through creating different types of file shares using the Webmin interface.</p>

<div class="cheat-sheet">
    <h2>🔑 Permissions Cheat Sheet</h2>
    <p>Use these <strong>Octal Codes</strong> in the <em>"Create with permissions"</em> field:</p>
    <table>
        <tr><th>Code</th><th>Type</th><th>Meaning</th></tr>
        <tr><td><strong>700</strong></td><td>Private</td><td>Owner has full access. Nobody else.</td></tr>
        <tr><td><strong>770</strong></td><td>Group</td><td>Owner and Group have access. Others blocked.</td></tr>
        <tr><td><strong>777</strong></td><td>Public</td><td>Everyone can Read/Write.</td></tr>
    </table>
</div>

<div class="scenario">
    <h2>🔒 Scenario 1: Private Personal Folder</h2>
    <p>Accessible ONLY by you.</p>
    <div class="step">
        <h3>Part A: Creation</h3>
        <ul>
            <li><strong>Share name</strong>: <code>myshare_private</code></li>
            <li><strong>Create with owner</strong>: <code>&lt;your_username&gt;</code></li>
            <li><strong>Create with permissions</strong>: <code>700</code></li>
        </ul>
    </div>
    <div class="step">
        <h3>Part B: Access Control</h3>
        <ul>
            <li><strong>Writable</strong>: Yes</li>
            <li><strong>Valid Users</strong>: <code>&lt;your_username&gt;</code></li>
        </ul>
    </div>
    <div class="step">
        <h3>Part C: File Permission Options</h3>
        <ul>
            <li><strong>New Unix file mode</strong>: <code>600</code></li>
            <li><strong>New Unix directory mode</strong>: <code>700</code></li>
            <li><strong>Force Unix user</strong>: <code>&lt;your_username&gt;</code></li>
        </ul>
    </div>
</div>

<div class="scenario">
    <h2>👥 Scenario 2: Private Group Share</h2>
    <p>Accessible by a specific team (e.g. editors).</p>
    <div class="step">
        <h3>Part A: Creation</h3>
        <ul>
            <li><strong>Share name</strong>: <code>team_projects</code></li>
            <li><strong>Create with group</strong>: <code>&lt;group_name&gt;</code></li>
            <li><strong>Create with permissions</strong>: <code>770</code></li>
        </ul>
    </div>
    <div class="step">
        <h3>Part B: Access Control</h3>
        <ul>
            <li><strong>Writable</strong>: Yes</li>
            <li><strong>Valid Users</strong>: <code>@&lt;group_name&gt;</code></li>
        </ul>
    </div>
    <div class="step">
        <h3>Part C: File Permission Options</h3>
        <ul>
            <li><strong>New Unix file mode</strong>: <code>660</code></li>
            <li><strong>New Unix directory mode</strong>: <code>770</code></li>
            <li><strong>Force Unix group</strong>: <code>&lt;group_name&gt;</code></li>
        </ul>
    </div>
</div>

<div class="scenario">
    <h2>🌍 Scenario 3: Public Guest Share</h2>
    <p>Everyone on network can Read/Write.</p>
    <div class="step">
        <h3>Part A: Creation</h3>
        <ul>
            <li><strong>Share name</strong>: <code>public_drop</code></li>
            <li><strong>Create with owner</strong>: <code>nobody</code></li>
            <li><strong>Create with group</strong>: <code>nogroup</code></li>
            <li><strong>Create with permissions</strong>: <code>777</code></li>
        </ul>
    </div>
    <div class="note">
        <strong>Why nobody?</strong> It maps to the default Guest account, preventing permission errors.
    </div>
    <div class="step">
        <h3>Part B: Access Control</h3>
        <ul>
            <li><strong>Writable</strong>: Yes</li>
            <li><strong>Guest Access</strong>: Yes</li>
            <li><strong>Guest Unix User</strong>: <code>nobody</code></li>
        </ul>
    </div>
    <div class="step">
        <h3>Part C: File Permission Options</h3>
        <ul>
            <li><strong>New Unix file mode</strong>: <code>666</code></li>
            <li><strong>New Unix directory mode</strong>: <code>777</code></li>
            <li><strong>Force Unix user</strong>: <code>nobody</code></li>
        </ul>
    </div>
</div>

</body>
</html>
EOF

    # Fix Permissions so the user can open it
    # Use PI_USER or SMB_USER to determine owner
    OWNER="${PI_USER:-root}"
    if id "$OWNER" &>/dev/null; then
        chown "$OWNER":"$OWNER" "$GUIDE_PATH"
    fi
    chmod 644 "$GUIDE_PATH"

    chmod 644 "$GUIDE_PATH"

    if [ -f "$GUIDE_PATH" ]; then
         # Silent permission set
         chmod 644 "$GUIDE_PATH"
         # echo "SUCCESS: Guide created at $GUIDE_PATH" <--- Silenced for cleaner summary
    else
         echo "WARNING: Webmin Guide not found at $GUIDE_PATH"
    fi
else
    echo "Skipping Webmin (webmin_enabled != true)"
fi

echo "--- File Sharing Setup Complete ---"
