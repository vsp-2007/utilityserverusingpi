#!/bin/bash
# Detailed Debugging of Port 80 Usage

echo "--- Checking Port 80 ---"
# Check using ss (modern tool)
if command -v ss >/dev/null; then
    echo "ss -tlpn output:"
    ss -tlpn | grep :80
else
    # Fallback to netstat
    if command -v netstat >/dev/null; then
        echo "netstat -tulpn output:"
        netstat -tulpn | grep :80
    else
        echo "Neither ss nor netstat found."
    fi
fi

# Try lsof if available
if command -v lsof >/dev/null; then
    echo "lsof output:"
    lsof -i :80
fi

echo "--- Checking Lighttpd ---"
if command -v lighttpd >/dev/null; then
    echo "Lighttpd path: $(which lighttpd)"
    echo "Config Dir:"
    ls -la /etc/lighttpd/ 2>/dev/null
    
    echo "Lighttpd Status:"
    systemctl status lighttpd --no-pager 2>/dev/null || echo "Service not found/running"
else
    echo "Lighttpd not found in PATH."
fi

echo "--- Checking Apache/Other ---"
if systemctl is-active apache2 >/dev/null 2>&1; then
    echo "Apache2 is running!"
fi

echo "--- Debug Complete ---"
