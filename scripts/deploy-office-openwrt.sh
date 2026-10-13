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
TARGET="${OFFICE_NODE_SSH_USER:-root}@${OFFICE_NODE_SSH_HOST}"

echo "[1/2] Deploying Office OpenWrt GRE + NAT66 + Campus Direct Route to $TARGET..."
ssh $SSH_OPTS "$TARGET" "mkdir -p /data/auto_ssh && cat > /data/auto_ssh/office_gre.env" << ENV_EOF
DORM_DDNS_HOST="${DORM_DDNS_HOST:-}"
DORM_WAN_FALLBACK_IP="${DORM_WAN_FALLBACK_IP:-10.98.86.100}"
OFFICE_WAN_FALLBACK_IP="${OFFICE_WAN_FALLBACK_IP:-10.98.64.100}"
DORM_IPV6_PREFIX="${DORM_IPV6_PREFIX:-2001:da8:e000:c011::/64}"
DORM_ULA_PREFIX="${DORM_ULA_PREFIX:-fd00:3131:3131::/64}"
GRE_TUNNEL_MTU="${GRE_TUNNEL_MTU:-1476}"
GRE_OFFICE_IPV6="${GRE_OFFICE_IPV6:-fd00:cafe::1/64}"
GRE_DORM_IPV6_PEER="${GRE_DORM_IPV6%/*}"
ENV_EOF

ssh $SSH_OPTS "$TARGET" "cat > /data/auto_ssh/setup_gre_office.sh && chmod +x /data/auto_ssh/setup_gre_office.sh" << 'REMOTE_OFFICE_SH'
#!/bin/sh
[ -f /data/auto_ssh/office_gre.env ] && . /data/auto_ssh/office_gre.env

WAN_GW=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.route[0].nexthop')
WAN_DEV=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.l3_device')
[ -z "$WAN_DEV" ] && WAN_DEV="eth0.1"
[ -n "$WAN_GW" ] && ip route replace 10.98.0.0/16 via "$WAN_GW" dev "$WAN_DEV"

DORM_IP=""
if [ -n "${DORM_DDNS_HOST:-}" ]; then
    DORM_IP=$(nslookup "$DORM_DDNS_HOST" 223.5.5.5 2>/dev/null | awk '/Address.* 10\./ {print $NF}' | head -n 1)
fi
[ -z "$DORM_IP" ] && DORM_IP="$DORM_WAN_FALLBACK_IP"

LOCAL_IP=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address')
[ -z "$LOCAL_IP" ] && LOCAL_IP="$OFFICE_WAN_FALLBACK_IP"

if ip link show gre-dorm >/dev/null 2>&1; then
    ip tunnel change gre-dorm remote "$DORM_IP" local "$LOCAL_IP" ttl 64 2>/dev/null || true
else
    ip tunnel add gre-dorm mode gre remote "$DORM_IP" local "$LOCAL_IP" ttl 64 2>/dev/null || true
fi
ip link set gre-dorm mtu "${GRE_TUNNEL_MTU:-1476}" txqueuelen 1000 up 2>/dev/null || true
ip -6 addr add "${GRE_OFFICE_IPV6:-fd00:cafe::1/64}" dev gre-dorm 2>/dev/null || true

iptables -C zone_wan_input -p gre -s 10.98.0.0/16 -j ACCEPT 2>/dev/null || iptables -I zone_wan_input -p gre -s 10.98.0.0/16 -j ACCEPT
iptables -C INPUT -p gre -s 10.98.0.0/16 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p gre -s 10.98.0.0/16 -j ACCEPT
iptables -C OUTPUT -p gre -d 10.98.0.0/16 -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -p gre -d 10.98.0.0/16 -j ACCEPT

ip6tables -C INPUT -i gre-dorm -j ACCEPT 2>/dev/null || ip6tables -I INPUT 1 -i gre-dorm -j ACCEPT
ip6tables -C FORWARD -i gre-dorm -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 1 -i gre-dorm -j ACCEPT
ip6tables -C FORWARD -o gre-dorm -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 1 -o gre-dorm -j ACCEPT

for pfx in "$DORM_IPV6_PREFIX" "$DORM_ULA_PREFIX" "fd00:cafe::/64"; do
    ip6tables -t nat -C POSTROUTING -s "$pfx" -o "$WAN_DEV" -j MASQUERADE 2>/dev/null ||         ip6tables -t nat -I POSTROUTING 1 -s "$pfx" -o "$WAN_DEV" -j MASQUERADE
done

ip -6 route replace "$DORM_IPV6_PREFIX" via "$GRE_DORM_IPV6_PEER" dev gre-dorm metric 1024
ip -6 route replace "$DORM_ULA_PREFIX" via "$GRE_DORM_IPV6_PEER" dev gre-dorm metric 1024

for q in /sys/class/net/eth0/queues/rx-* /sys/class/net/"$WAN_DEV"/queues/rx-* /sys/class/net/gre-dorm/queues/rx-* /sys/class/net/br-lan/queues/rx-*; do
    [ -f "$q/rps_cpus" ] && echo 3 > "$q/rps_cpus" 2>/dev/null || true
done
REMOTE_OFFICE_SH

ssh $SSH_OPTS "$TARGET" '
uci set firewall.gre_office_include=include
uci set firewall.gre_office_include.type="script"
uci set firewall.gre_office_include.path="/data/auto_ssh/setup_gre_office.sh"
uci set firewall.gre_office_include.enabled="1"
uci commit firewall
sh /data/auto_ssh/setup_gre_office.sh
'
echo "[2/2] Office OpenWrt Router configuration complete."
