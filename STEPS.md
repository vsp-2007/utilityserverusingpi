# Installation Steps

This guide explains how to install the Pi Server Setup suite using the provided orchestration script.

## Pre-requisites
- A clean installation of Raspberry Pi OS (Trixie).
- SSH access to your Raspberry Pi.
- Basic networking setup completed (e.g. connected to your WiFi or Ethernet).

## 🚀 How to Install

1. **Clone the Repository** (If you haven't already):
   Ensure you have downloaded this project to your Raspberry Pi.
   
2. **Make the Script Executable**:
   Navigate to the project directory and make the master installer executable:
   ```bash
   chmod +x install.sh
   ```

3. **Run the Master Installer**:
   Execute the installation script as `root`:
   ```bash
   sudo ./install.sh
   ```

4. **Follow the Interactive Menu**:
   You will be presented with the following options:
   ```text
   1) System Basics (Update, User, SSH, Tools)
   2) Network (Tailscale, Static IP Helper)
   3) Pi-hole (Ad Blocking)
   4) Monitoring Stack (Prometheus, Grafana, Alertmanager)
   5) File Sharing (Samba, Webmin)
   6) Utilities
   7) Telegram Bot
   8) Localsend (File Sharing App)
   9) Stirling-PDF (PDF Tools)
   10) Nginx Reverse Proxy (Domain Access)
   11) Cockpit (Web-based Administration)
   12) n8n Automation Engine
   A) Install Everything
   Q) Quit
   ```

   Select the numbers you wish to install, or press `A` to install the full stack.

5. **Provide Interactive Configuration**:
   During the setup, you might be asked for credentials such as:
   - System User (`PI_USER`)
   - Grafana Admin Password
   - Telegram Bot Tokens and Chat IDs
   - Samba User Configuration

6. **Review the Summary**:
   Once the script completes, it will display an **Installation Summary** detailing the specific IP addresses, local domain URLs, and ports for accessing each installed server component.
