# About Pi Server Setup

The **Pi Server Setup** project is designed to transform a standard Raspberry Pi into a production-ready, observable, and fully-featured home server. 

## 🌟 Core Philosophical Pillars

1. **Observability:** Every metric—CPU, RAM, Temperature, and Network—is tracked, retained, and visualized. Instead of guessing why the Pi is slow, Grafana provides immediate insights.
2. **Self-Healing & Resilience:** Core scripts handle common issues gracefully. Logging is size-limited (e.g., systemd journal capped at 500MB) to preserve the SD card, and UI scaling anomalies are automatically handled.
3. **Remote-First:** The server is designed to be fully manageable from anywhere on the planet. Tailscale connects the node securely via a P2P mesh network, abstracting away NAT traversal rules.
4. **Security & Autonomy:** Built-in Pi-hole ensures network-level ad-blocking. Critical alerts and real-time statuses are securely pushed directly into a private Telegram Bot.

## 🏗 Component Architecture
The installation relies on a master shell script (`install.sh`) which elegantly sources individual configuration variables, manages dependencies dynamically, and proxies installations out to modular component scripts (located in `scripts/`).

### System Highlights:
- **Dual Telegram Bot**: One bot actively streams Alertmanager logs to a private group, while another functions interactively so you can send `/status` queries from your phone.
- **Nginx Reverse Proxy**: Integrates friendly URLs (e.g., `webmin.home`, `pi.home`) for effortless in-network usage.
- **Automation at the Core**: Tools like `n8n` integrated natively, providing an IFTTT-like canvas directly from the Pi.

### Documentation & Reporting
We have fully documented the networking layout, technical architecture, and implementation details within `DOCUMENTATION.md` and the accompanying `Project_Report` logs.
