#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE="${1:-$SCRIPT_DIR/../.env}"
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: config file $ENV_FILE not found. Copy .env.example to .env first." >&2
    exit 1
fi
. "$ENV_FILE"

SSH_OPTS="-o ConnectTimeout=6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
TARGET="${OFFICE_NODE_SSH_USER:-root}@${OFFICE_NODE_SSH_HOST}"

echo "[1/4] Preparing kernel sysctl, modules & optional fnOS slimming on Office Linux Node ($TARGET)..."
ssh $SSH_OPTS "$TARGET" '
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if systemctl list-unit-files 2>/dev/null | grep -q "^trim_main.service"; then
    SERVICES="accountsrv.service ai_manager.service auto_thumbnailer.service avahi.service backup_service.service cloud_storage_dav.service containerd.service docker.service docker.socket dlcenter.service dockermgr.service dsmgr.service eventlogger_service.service filestor_service.service finder_service.service imagesrv.service mediasrv.service ModemManager.service mountmgr.service multiple-downloads.service network_service.service nfs-blkmap.service nfs-idmapd.service nfs-mountd.service nfs-server.service nfsdcld.service nmbd.service ovs-vswitchd.service ovsdb-server.service openvswitch-switch.service postgresql.service postgresql@15-main.service resmon_service.service rpc-statd.service rpc_broker.service rpcbind.service rpcbind.socket security_service.service share_service.service smbd.service smbftpd.service sysinfo_service.service sysrestore.service trim_app_center.service trim_app_cgi.service trim_connect.service trim_diskpowerd.service trim_file_monitor.service trim_http_cgi.service trim_main.service trim_nginx.service trim_sac.service trim_sharelink.service trim_trashbind.service trim_upload.service upnp.service upower.service usersrv.service webdav.service winbind.service wsdd2.service"
    systemctl stop $SERVICES 2>/dev/null || true
    systemctl disable $SERVICES 2>/dev/null || true
    systemctl mask $SERVICES 2>/dev/null || true
fi

modprobe tcp_bbr 2>/dev/null || true
modprobe ip_gre 2>/dev/null || true
modprobe ip6table_nat 2>/dev/null || true
printf "tcp_bbr\nip_gre\nip6table_nat\n" > /etc/modules-load.d/office-gateway.conf

cat > /etc/sysctl.d/99-router-forward.conf << "SYSCTL_EOF"
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rps_sock_flow_entries = 32768
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.netfilter.nf_conntrack_max = 262144
SYSCTL_EOF
sysctl --system >/dev/null
mkdir -p /etc/office-gateway /var/lib/office-gateway
'

echo "[2/4] Writing /etc/office-gateway/config.env to $TARGET..."
ssh $SSH_OPTS "$TARGET" "cat > /etc/office-gateway/config.env && chmod 600 /etc/office-gateway/config.env" << ENV_DATA
WAN_IF="${OFFICE_WAN_IF:-enp3s0}"
OFFICE_MAC_CLONE="${OFFICE_CLONE_MAC:-}"
OFFICE_DUID="${OFFICE_CLONE_DUID:-}"

ENABLE_RESCUE_WIFI="${ENABLE_RESCUE_WIFI:-1}"
RESCUE_WIFI_IF="${RESCUE_WIFI_IF:-wlp2s0}"
RESCUE_WIFI_SSID="${RESCUE_WIFI_SSID:-NUC-Rescue}"
RESCUE_WIFI_PSK="${RESCUE_WIFI_PSK:-ChangeMe123456}"
RESCUE_WIFI_CIDR="${RESCUE_WIFI_CIDR:-192.168.99.1/24}"

DORM_DDNS_HOST="${DORM_DDNS_HOST:-}"
DORM_FALLBACK_IP="${DORM_WAN_FALLBACK_IP:-10.98.86.100}"
GRE_IF="gre-dorm"
GRE_TUNNEL_MTU="${GRE_TUNNEL_MTU:-1476}"
GRE_LOCAL_V6="${GRE_OFFICE_IPV6:-fd00:cafe::1/64}"
GRE_PEER_V6="${GRE_DORM_IPV6%/*}"
GRE_LOCAL_V4="${GRE_OFFICE_IPV4:-10.255.255.1/30}"
GRE_PEER_V4="${GRE_DORM_IPV4%/*}"
DORM_PREFIX_1="${DORM_IPV6_PREFIX:-2001:da8:e000:c011::/64}"
DORM_PREFIX_2="${DORM_ULA_PREFIX:-fd00:3131:3131::/64}"

ENABLE_ZJU_L2TP="${ENABLE_OFFICE_L2TP:-0}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_TOKEN="${CF_API_TOKEN:-}"
OFFICE_REC_A="${OFFICE_CF_RECORD_A_ID:-}"
OFFICE_REC_AAAA="${OFFICE_CF_RECORD_AAAA_ID:-}"
ENV_DATA

echo "[3/4] Installing /usr/local/sbin/office-gateway-guardian & systemd timer on $TARGET..."
ssh $SSH_OPTS "$TARGET" "cat > /usr/local/sbin/office-gateway-guardian && chmod +x /usr/local/sbin/office-gateway-guardian" << 'GUARDIAN_EOF'
#!/bin/sh
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[ -f /etc/office-gateway/config.env ] && . /etc/office-gateway/config.env
STATE_DIR="/var/lib/office-gateway"
mkdir -p "$STATE_DIR"

if [ "${ENABLE_RESCUE_WIFI:-1}" = "1" ] && [ -d "/sys/class/net/${RESCUE_WIFI_IF:-wlp2s0}" ]; then
    if ! nmcli connection show "${RESCUE_WIFI_SSID:-NUC-Rescue}" >/dev/null 2>&1; then
        nmcli connection add type wifi ifname "$RESCUE_WIFI_IF" con-name "$RESCUE_WIFI_SSID" autoconnect yes ssid "$RESCUE_WIFI_SSID"             802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.channel 6             wifi-sec.key-mgmt wpa-psk wifi-sec.proto rsn wifi-sec.pairwise ccmp wifi-sec.group ccmp             wifi-sec.psk "$RESCUE_WIFI_PSK"             ipv4.method shared ipv4.addresses "$RESCUE_WIFI_CIDR" ipv4.never-default yes ipv6.method ignore >/dev/null 2>&1 || true
    fi
    if ! ip -4 addr show dev "$RESCUE_WIFI_IF" 2>/dev/null | grep -q "${RESCUE_WIFI_CIDR%/*}"; then
        nmcli connection up "$RESCUE_WIFI_SSID" >/dev/null 2>&1 || true
    fi
fi

WAN_CON=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: "\$2=="$WAN_IF" {print \$1; exit}")
[ -z "$WAN_CON" ] && WAN_CON="Wired connection 1"
nmcli connection modify "$WAN_CON" connection.autoconnect yes connection.autoconnect-retries 0 ipv4.route-metric 200 802-3-ethernet.wake-on-lan magic >/dev/null 2>&1 || true
[ -n "${OFFICE_MAC_CLONE:-}" ] && nmcli connection modify "$WAN_CON" 802-3-ethernet.cloned-mac-address "$OFFICE_MAC_CLONE" >/dev/null 2>&1 || true
[ -n "${OFFICE_DUID:-}" ] && nmcli connection modify "$WAN_CON" ipv6.dhcp-duid "$OFFICE_DUID" >/dev/null 2>&1 || true

CARRIER=$(cat /sys/class/net/"$WAN_IF"/carrier 2>/dev/null || echo 0)
IP4=$(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{split($4,a,"/"); print a[1]; exit}')
if [ "$CARRIER" = "1" ] && [ -z "$IP4" ]; then
    nmcli connection up "$WAN_CON" >/dev/null 2>&1 || true
    sleep 3
    IP4=$(ip -4 -o addr show dev "$WAN_IF" scope global | awk '{split($4,a,"/"); print a[1]; exit}')
fi

ethtool -K "$WAN_IF" gro on gso on tso on sg on rx on tx on 2>/dev/null || true
ethtool -s "$WAN_IF" wol g 2>/dev/null || true
ip link set "$WAN_IF" txqueuelen 2000 2>/dev/null || true
sysctl -w net.ipv6.conf."$WAN_IF".accept_ra=2 >/dev/null 2>&1 || true
for q in /sys/class/net/"$WAN_IF"/queues/rx-*; do
    [ -f "$q/rps_cpus" ] && echo f > "$q/rps_cpus" 2>/dev/null || true
    [ -f "$q/rps_flow_cnt" ] && echo 4096 > "$q/rps_flow_cnt" 2>/dev/null || true
done

IP6=$(ip -6 -o addr show dev "$WAN_IF" scope global | awk '!/temporary/ && !/deprecated/ && !/tentative/ && $4 ~ /^[23]/ {split($4,a,"/"); print a[1]; exit}')
WAN_GW=$(ip -4 route show dev "$WAN_IF" proto dhcp | awk '/default/ {print $3; exit}')
[ -z "$WAN_GW" ] && WAN_GW=$(ip -4 route show dev "$WAN_IF" | awk '/10\.98\.0\.0\/16/ {print $3; exit}')

IS_OFFICE="0"
case "$IP4" in
    10.98.*) IS_OFFICE="1" ;;
esac

if [ "$IS_OFFICE" = "0" ]; then
    echo "dorm-standby" > "$STATE_DIR/mode"
    ip link show "$GRE_IF" >/dev/null 2>&1 && ip link del "$GRE_IF" 2>/dev/null || true
    exit 0
fi

echo "office-active" > "$STATE_DIR/mode"

if [ -n "$WAN_GW" ]; then
    ip route replace 10.0.0.0/8 via "$WAN_GW" dev "$WAN_IF"
    ip route replace 10.98.0.0/16 via "$WAN_GW" dev "$WAN_IF"
    ip route replace 10.10.0.0/16 via "$WAN_GW" dev "$WAN_IF"
    ip route replace 10.0.2.0/24 via "$WAN_GW" dev "$WAN_IF"
fi

DORM_IP=""
if [ -n "${DORM_DDNS_HOST:-}" ]; then
    DORM_IP=$(dig +short +time=2 +tries=1 @2400:3200::1 A "$DORM_DDNS_HOST" 2>/dev/null | awk '/^10\./ {print; exit}')
    [ -z "$DORM_IP" ] && DORM_IP=$(dig +short +time=2 +tries=1 @10.10.0.21 A "$DORM_DDNS_HOST" 2>/dev/null | awk '/^10\./ {print; exit}')
fi
[ -z "$DORM_IP" ] && DORM_IP="$DORM_FALLBACK_IP"

[ -n "$WAN_GW" ] && [ -n "$DORM_IP" ] && ip route replace "$DORM_IP/32" via "$WAN_GW" dev "$WAN_IF"

if ip link show "$GRE_IF" >/dev/null 2>&1; then
    ip tunnel change "$GRE_IF" remote "$DORM_IP" local "$IP4" ttl 64 2>/dev/null || true
else
    ip tunnel add "$GRE_IF" mode gre remote "$DORM_IP" local "$IP4" ttl 64 2>/dev/null || true
fi

ip link set "$GRE_IF" mtu "${GRE_TUNNEL_MTU:-1476}" txqueuelen 1000 up 2>/dev/null || true
ethtool -K "$GRE_IF" gro on gso on tso on sg on 2>/dev/null || true
for q in /sys/class/net/"$GRE_IF"/queues/rx-*; do
    [ -f "$q/rps_cpus" ] && echo f > "$q/rps_cpus" 2>/dev/null || true
done

ip -4 addr replace "$GRE_LOCAL_V4" dev "$GRE_IF"
ip -6 addr replace "$GRE_LOCAL_V6" dev "$GRE_IF"
ip -6 route replace "$DORM_PREFIX_1" via "$GRE_PEER_V6" dev "$GRE_IF" metric 100
ip -6 route replace "$DORM_PREFIX_2" via "$GRE_PEER_V6" dev "$GRE_IF" metric 100

iptables -t raw -C PREROUTING -p gre -s 10.98.0.0/16 -j CT --notrack 2>/dev/null || iptables -t raw -I PREROUTING 1 -p gre -s 10.98.0.0/16 -j CT --notrack
iptables -t raw -C OUTPUT -p gre -d 10.98.0.0/16 -j CT --notrack 2>/dev/null || iptables -t raw -I OUTPUT 1 -p gre -d 10.98.0.0/16 -j CT --notrack
iptables -C INPUT -p gre -s 10.98.0.0/16 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p gre -s 10.98.0.0/16 -j ACCEPT
iptables -C OUTPUT -p gre -d 10.98.0.0/16 -j ACCEPT 2>/dev/null || iptables -I OUTPUT 1 -p gre -d 10.98.0.0/16 -j ACCEPT

ip6tables -C INPUT -i "$GRE_IF" -j ACCEPT 2>/dev/null || ip6tables -I INPUT 1 -i "$GRE_IF" -j ACCEPT
ip6tables -C FORWARD -i "$GRE_IF" -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 1 -i "$GRE_IF" -j ACCEPT
ip6tables -C FORWARD -o "$GRE_IF" -j ACCEPT 2>/dev/null || ip6tables -I FORWARD 1 -o "$GRE_IF" -j ACCEPT
ip6tables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null ||     ip6tables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

for pfx in "$DORM_PREFIX_1" "$DORM_PREFIX_2" "fd00:cafe::/64"; do
    ip6tables -t nat -C POSTROUTING -s "$pfx" -o "$WAN_IF" -j MASQUERADE 2>/dev/null ||         ip6tables -t nat -I POSTROUTING 1 -s "$pfx" -o "$WAN_IF" -j MASQUERADE
done

if [ -f /root/.ssh/id_rsa ] && [ -n "$DORM_IP" ] && [ -n "$IP4" ]; then
    LAST_PUSH_IP=$(cat "$STATE_DIR/last_pushed_dorm_ip" 2>/dev/null || true)
    if [ "$IP4" != "$LAST_PUSH_IP" ]; then
        if ssh -o ConnectTimeout=4 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null                -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa -i /root/.ssh/id_rsa                root@"$DORM_IP" "echo $IP4 > /tmp/office_nuc_ip; ip tunnel change gre-office remote $IP4 ttl 64 2>/dev/null || true; ip link set gre-office mtu 1476 txqueuelen 1000 up" 2>/dev/null; then
            echo "$IP4" > "$STATE_DIR/last_pushed_dorm_ip"
        fi
    fi
fi

if [ "${ENABLE_ZJU_L2TP:-0}" = "0" ]; then
    [ -n "$WAN_GW" ] && ip route replace default via "$WAN_GW" dev "$WAN_IF" metric 200
    ip route replace default via "$GRE_PEER_V4" dev "$GRE_IF" metric 50
fi

if [ -n "${CF_ZONE_ID:-}" ] && [ -n "${CF_TOKEN:-}" ]; then
    for pair in "${OFFICE_REC_A:-}:$IP4" "${OFFICE_REC_AAAA:-}:$IP6"; do
        rec_id="${pair%%:*}"
        val="${pair#*:}"
        if [ -n "$rec_id" ] && [ -n "$val" ]; then
            old_val=$(cat "$STATE_DIR/cf_$rec_id" 2>/dev/null || true)
            if [ "$val" != "$old_val" ]; then
                res=$(curl -6 -s --max-time 6 -X PATCH "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$rec_id"                     -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" -d "{\"content\":\"$val\"}" 2>/dev/null || true)
                echo "$res" | grep -q '"success":true' && echo "$val" > "$STATE_DIR/cf_$rec_id"
            fi
        fi
    done
fi
GUARDIAN_EOF

ssh $SSH_OPTS "$TARGET" '
cat > /etc/systemd/system/office-gateway-guardian.service << "UNIT_EOF"
[Unit]
Description=Office IPv6 GRE Gateway & DDNS Guardian
After=network-online.target NetworkManager.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/office-gateway-guardian
UNIT_EOF

cat > /etc/systemd/system/office-gateway-guardian.timer << "TIMER_EOF"
[Unit]
Description=Run Office IPv6 GRE Gateway Guardian every 60s

[Timer]
OnBootSec=15s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
TIMER_EOF

systemctl daemon-reload
systemctl enable --now office-gateway-guardian.timer
/usr/local/sbin/office-gateway-guardian
'

echo "[4/4] Office Linux Node configuration complete."
