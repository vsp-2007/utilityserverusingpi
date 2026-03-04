#!/usr/bin/env python3
import sys
import json
import os
import requests

# Read configuration from environment or file
# In this setup, the environment variables are sourced by Wazuh from the service file
# or hardcoded by the installer into a secure config file.
CONFIG_FILE = "/var/ossec/integrations/telegram-config.json"

def main():
    try:
        # Read alert from stdin
        alert_file = open(sys.argv[1], 'r') if len(sys.argv) > 1 else sys.stdin
        alert = json.load(alert_file)
    except Exception as e:
        sys.exit(0)  # Exit silently if no valid JSON

    # Load Token and Chat ID
    if not os.path.exists(CONFIG_FILE):
        sys.exit(0)
    
    with open(CONFIG_FILE, 'r') as f:
        config = json.load(f)
    
    token = config.get("TELEGRAM_ADMIN_TOKEN")
    chat_id = config.get("TELEGRAM_ADMIN_CHAT_ID")
    
    if not token or not chat_id:
        sys.exit(0)

    # Parse Alert Data
    rule_id = alert.get("rule", {}).get("id")
    level = alert.get("rule", {}).get("level", 0)
    description = alert.get("rule", {}).get("description", "Unknown Alert")
    
    # We are specifically looking for scan completion events
    # Rule 503 is FIM (Syscheck database populated/updated)
    # Rule 514 is Rootcheck scan completed
    # Rule 20002 is Vulnerability Scanner completed
    
    is_scan_complete = str(rule_id) in ["503", "514", "20002"]
    
    message = ""
    
    if is_scan_complete:
        message = (
            f"✅ **System Security Scan Complete**\n\n"
            f"**Action:** {description}\n"
            f"**Note:** If no prior warnings were sent, the system is clean."
        )
    else:
         # Only send alerts level 7 and above to reduce spam
        if level >= 7:
             message = (
                 f"🚨 **WAZUH ALERT (Level {level})** 🚨\n\n"
                 f"**Description:** {description}\n\n"
             )
             # Add extra context if it's a vulnerability or rootcheck
             if "vulnerability" in alert:
                  vuln = alert["vulnerability"]
                  message += f"**CVE:** {vuln.get('cve')}\n"
                  message += f"**Package:** {vuln.get('package', {}).get('name')}\n"
                  message += f"**Severity:** {vuln.get('severity')}\n"
             elif "syscheck" in alert:
                  syscheck = alert["syscheck"]
                  message += f"**File:** {syscheck.get('path')}\n"
                  message += f"**Event:** {syscheck.get('event')}\n"
             else:
                  # General details
                 full_log = alert.get("full_log", "")
                 if len(full_log) > 200:
                     full_log = full_log[:200] + "..."
                 message += f"**Log:** `{full_log}`"
        else:
             sys.exit(0) # Do not send low level alerts immediately
    
    if message:
        url = f"https://api.telegram.org/bot{token}/sendMessage"
        payload = {
            "chat_id": chat_id,
            "text": message,
            "parse_mode": "Markdown"
        }
        try:
            requests.post(url, json=payload, timeout=5)
        except:
            pass # Fail silently

if __name__ == "__main__":
    main()
