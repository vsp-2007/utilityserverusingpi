#!/bin/bash
echo "========================================="
echo "   Stirling-PDF Diagnostic Tool"
echo "========================================="

echo
echo "1. System Information"
echo "---------------------"
uname -a
echo "Memory:"
free -h
echo "Disk Space:"
df -h /opt/Stirling-PDF

echo
echo "2. Java Check"
echo "-------------"
if command -v java >/dev/null; then
    java -version 2>&1
else
    echo "❌ Java not found in PATH!"
fi

echo
echo "3. File Verification"
echo "--------------------"
ls -lh /opt/Stirling-PDF/
echo "Settings.yml:"
if [ -f /opt/Stirling-PDF/settings.yml ]; then
    cat /opt/Stirling-PDF/settings.yml
else
    echo "❌ settings.yml missing!"
fi

echo
echo "4. Service Status"
echo "-----------------"
systemctl status stirling-pdf --no-pager

echo
echo "5. Recent Logs (Last 100 lines)"
echo "-------------------------------"
if command -v journalctl >/dev/null; then
    journalctl -u stirling-pdf -n 100 --no-pager
else
    echo "journalctl not available."
fi

echo
echo "6. Network Check (Port 8080)"
echo "----------------------------"
if command -v ss >/dev/null; then
    ss -tulpn | grep 8080 || echo "Nothing listening on port 8080"
else
    netstat -tulpn | grep 8080 || echo "Nothing listening on port 8080"
fi

echo
echo "7. Firewall Check"
echo "-----------------"
if command -v ufw >/dev/null; then
    ufw status | grep 8080
else
    echo "UFW not installed."
fi

echo "========================================="
echo "End of Diagnostics"
