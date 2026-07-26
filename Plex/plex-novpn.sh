#!/bin/bash
# Bypass PureVPN routing for Plex container traffic

RT_TABLES="/usr/share/iproute2/rt_tables"
TABLE_ID=100
TABLE_NAME="novpn"

# Add routing table entry if not already present
grep -q "^${TABLE_ID} ${TABLE_NAME}" "$RT_TABLES" || echo "${TABLE_ID} ${TABLE_NAME}" >> "$RT_TABLES"

# Populate the novpn table using numeric ID (replace to avoid duplicates)
ip route replace default via 192.168.0.254 dev bond0 table $TABLE_ID
ip route replace 192.168.0.0/24 dev bond0 src 192.168.0.5 table $TABLE_ID

# Add fwmark rule — remove first to avoid duplicates on restart
ip rule del fwmark $TABLE_ID table $TABLE_ID 2>/dev/null || true
ip rule add fwmark $TABLE_ID table $TABLE_ID priority 100

# Add iptables rules (idempotent — only adds if not already present)
declare -A RULES=(
    [tcp]="32400 32469 34400 8443"
    [udp]="1900 32410 32412 32413 32414"
)

for proto in "${!RULES[@]}"; do
    for port in ${RULES[$proto]}; do
        iptables -t mangle -C OUTPUT -p "$proto" --sport "$port" -j MARK --set-mark $TABLE_ID 2>/dev/null || \
            iptables -t mangle -A OUTPUT -p "$proto" --sport "$port" -j MARK --set-mark $TABLE_ID
    done
done
