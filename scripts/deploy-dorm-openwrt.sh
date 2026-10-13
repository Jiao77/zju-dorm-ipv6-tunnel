#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE="${1:-$SCRIPT_DIR/../.env}"
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: config file $ENV_FILE not found. Copy .env.example to .env first." >&2
    exit 1
fi
. "$ENV_FILE"

SSH_OPTS="-o ConnectTimeout=6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa"
TARGET="${DORM_ROUTER_SSH_USER:-root}@${DORM_ROUTER_LAN_IP:-192.168.31.1}"

echo "[1/3] Deploying campus static route hotplug & /data/firewall.user to Dorm Router ($TARGET)..."
ssh $SSH_OPTS "$TARGET" "cat > /data/71-vpn-static-route.sh" << 'REMOTE_HOTPLUG'
#!/bin/sh
if [ "$ACTION" = "ifup" ]; then
    gw=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.route[0].nexthop')
    dev=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.l3_device')
    if [ -n "$gw" ] && [ -n "$dev" ]; then
        ip route replace 10.98.0.0/16 via "$gw" dev "$dev"
    fi
fi
REMOTE_HOTPLUG

ssh $SSH_OPTS "$TARGET" "
chmod +x /data/71-vpn-static-route.sh
cp -f /data/71-vpn-static-route.sh /etc/hotplug.d/iface/71-vpn-static-route
chmod +x /etc/hotplug.d/iface/71-vpn-static-route

cat > /data/dorm_gre.env << 'ENV_EOF'
OFFICE_DDNS_HOST=\"${OFFICE_DDNS_HOST:-}\"
OFFICE_WAN_FALLBACK_IP=\"${OFFICE_WAN_FALLBACK_IP:-10.98.64.100}\"
DORM_WAN_FALLBACK_IP=\"${DORM_WAN_FALLBACK_IP:-10.98.86.100}\"
DORM_IPV6_PREFIX=\"${DORM_IPV6_PREFIX:-2001:da8:e000:c011::/64}\"
GRE_TUNNEL_MTU=\"${GRE_TUNNEL_MTU:-1476}\"
GRE_DORM_IPV6=\"${GRE_DORM_IPV6:-fd00:cafe::2/64}\"
GRE_OFFICE_IPV6_PEER=\"${GRE_OFFICE_IPV6%/*}\"
GRE_DORM_IPV4=\"${GRE_DORM_IPV4:-10.255.255.2/30}\"
ENV_EOF
"

ssh $SSH_OPTS "$TARGET" "cat > /data/setup_gre_dorm.sh" << 'REMOTE_FW'
#!/bin/sh
[ -f /data/dorm_gre.env ] && . /data/dorm_gre.env

WAN_GW=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.route[0].nexthop')
WAN_DEV=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.l3_device')
[ -n "$WAN_GW" ] && [ -n "$WAN_DEV" ] && ip route replace 10.98.0.0/16 via "$WAN_GW" dev "$WAN_DEV"

OFFICE_IP=""
if [ -f /tmp/office_nuc_ip ]; then
    OFFICE_IP=$(cat /tmp/office_nuc_ip 2>/dev/null)
fi
if [ -z "$OFFICE_IP" ] && [ -n "${OFFICE_DDNS_HOST:-}" ]; then
    OFFICE_IP=$(nslookup "$OFFICE_DDNS_HOST" 223.5.5.5 2>/dev/null | awk '/Address.* 10\./ {print $NF}' | head -n 1)
fi
[ -z "$OFFICE_IP" ] && OFFICE_IP="$OFFICE_WAN_FALLBACK_IP"

LOCAL_IP=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address')
[ -z "$LOCAL_IP" ] && LOCAL_IP="$DORM_WAN_FALLBACK_IP"

if ip link show gre-office >/dev/null 2>&1; then
    ip tunnel change gre-office remote "$OFFICE_IP" local "$LOCAL_IP" ttl 64 2>/dev/null || true
else
    ip tunnel add gre-office mode gre remote "$OFFICE_IP" local "$LOCAL_IP" ttl 64 2>/dev/null || true
fi
ip link set gre-office mtu "${GRE_TUNNEL_MTU:-1476}" txqueuelen 1000 up 2>/dev/null || true
ip -4 addr replace "${GRE_DORM_IPV4:-10.255.255.2/30}" dev gre-office 2>/dev/null || true
ip -6 addr add "${GRE_DORM_IPV6:-fd00:cafe::2/64}" dev gre-office 2>/dev/null || true

iptables -C zone_wan_input -p gre -s 10.98.0.0/16 -j ACCEPT 2>/dev/null || iptables -I zone_wan_input -p gre -s 10.98.0.0/16 -j ACCEPT
iptables -C zone_wan_input -p tcp -s 10.98.0.0/16 --dport 22 -j ACCEPT 2>/dev/null || iptables -I zone_wan_input -p tcp -s 10.98.0.0/16 --dport 22 -j ACCEPT
iptables -C zone_wan_input -p icmp -s 10.98.0.0/16 -j ACCEPT 2>/dev/null || iptables -I zone_wan_input 1 -p icmp -s 10.98.0.0/16 -j ACCEPT
iptables -C INPUT -p gre -s 10.98.0.0/16 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p gre -s 10.98.0.0/16 -j ACCEPT
iptables -C OUTPUT -p gre -d 10.98.0.0/16 -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -p gre -d 10.98.0.0/16 -j ACCEPT
iptables -C INPUT -i gre-office -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i gre-office -j ACCEPT
iptables -C FORWARD -i gre-office -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i gre-office -j ACCEPT
iptables -C FORWARD -o gre-office -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -o gre-office -j ACCEPT
iptables -t nat -C POSTROUTING -s 10.255.255.0/30 -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s 10.255.255.0/30 -j MASQUERADE
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

while ip6tables -D INPUT -i gre-office -j ACCEPT 2>/dev/null; do :; done
ip6tables -I INPUT 1 -i gre-office -j ACCEPT
while ip6tables -D FORWARD -i gre-office -j ACCEPT 2>/dev/null; do :; done
while ip6tables -D FORWARD -o gre-office -j ACCEPT 2>/dev/null; do :; done
ip6tables -I FORWARD 1 -i gre-office -j ACCEPT
ip6tables -I FORWARD 1 -o gre-office -j ACCEPT

# 清空本地重复 NAT66，由工位节点统一在出口做单次 NAT66，使宿舍端命中 SFE 快径
ip6tables -t nat -F miwifi_nat6 2>/dev/null || true

LAN_PREFIX_BASE="${DORM_IPV6_PREFIX%::*}"
ip -6 addr add "${LAN_PREFIX_BASE}::1/64" dev br-lan 2>/dev/null || true
ip -6 route replace default via "${GRE_OFFICE_IPV6_PEER:-fd00:cafe::1}" dev gre-office metric 512

for q in /sys/class/net/eth0/queues/rx-* /sys/class/net/eth0.1/queues/rx-* /sys/class/net/gre-office/queues/rx-* /sys/class/net/br-lan/queues/rx-*; do
    [ -f "$q/rps_cpus" ] && echo f > "$q/rps_cpus" 2>/dev/null || true
done
REMOTE_FW

echo "[2/3] Registering firewall include & executing /data/setup_gre_dorm.sh..."
ssh $SSH_OPTS "$TARGET" '
chmod +x /data/setup_gre_dorm.sh
touch /data/firewall.user
chmod +x /data/firewall.user
grep -q "/data/setup_gre_dorm.sh" /data/firewall.user || echo "sh /data/setup_gre_dorm.sh" >> /data/firewall.user
uci set firewall.gre_dorm_include=include
uci set firewall.gre_dorm_include.type="script"
uci set firewall.gre_dorm_include.path="/data/firewall.user"
uci set firewall.gre_dorm_include.enabled="1"
uci set firewall.gre_dorm_include.reload="1"
uci set dhcp.lan.ra="server"
uci set dhcp.lan.dhcpv6="server"
uci set dhcp.lan.ra_default="2"
uci set dhcp.lan.ra_preference="high"
uci commit firewall
uci commit dhcp
/etc/init.d/odhcpd reload 2>/dev/null || true
sh /data/setup_gre_dorm.sh
'

echo "[3/3] Dorm Router configuration complete."
