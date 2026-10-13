#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENV_FILE="${1:-$SCRIPT_DIR/../.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

DORM_HOST="${DORM_ROUTER_SSH_USER:-root}@${DORM_ROUTER_LAN_IP:-192.168.31.1}"
SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedKeyTypes=+ssh-rsa"

echo "=== [1/4] Checking Dorm Router ($DORM_HOST) Tunnel & Route State ==="
ssh $SSH_OPTS "$DORM_HOST" '
ip -d link show gre-office
ip -6 route show default
echo "--- Ping Office GRE Endpoint (fd00:cafe::1) ---"
ping6 -c 3 -W 2 fd00:cafe::1
'

echo "=== [2/4] Checking Public IPv6 Connectivity from Dorm Router ==="
ssh $SSH_OPTS "$DORM_HOST" '
ping6 -c 3 -W 2 2400:3200::1
'

echo "=== [3/4] Checking Local Client IPv6 Route & Egress ==="
if command -v curl >/dev/null 2>&1; then
    printf "Local Public IPv6 Egress: "
    curl -6 -s --max-time 5 https://www.cloudflare.com/cdn-cgi/trace | grep "^ip=" || echo "N/A (check local proxy/TUN settings)"
fi

echo "=== [4/4] Running 6s CERNET2 IPv6 Download Speed Benchmark ==="
TEST_URL="https://[2409:8700:2482:710::fe55:2840]/debian/pool/main/f/firefox-esr/firefox-esr_140.16.0esr.orig.tar.xz"
curl -g -6 -k -H "Host: mirrors.bfsu.edu.cn" -s -o /dev/null     -w "Single-Stream Speed: %{speed_download} B/s (%{size_download} bytes in %{time_total}s, HTTP %{http_code})\n"     --max-time 6 "$TEST_URL" || true
