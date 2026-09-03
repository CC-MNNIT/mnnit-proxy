#!/usr/bin/env bash
# mnnit-proxy integration tests  -  full install path with a local proxy stand-in.
# Designed for GitHub Actions Ubuntu runners (or any Ubuntu/Debian box with sudo).
#
# What it does:
#   1. Installs tinyproxy with edcguest/edcguest BasicAuth on 127.0.0.1:3128
#      (stands in for the college proxy  -  same HTTP-proxy + auth mechanics)
#   2. Runs install.sh unattended: --yes --skip-ip --no-tun
#      (exercises the real mihomo download path + systemd unit + config gen)
#   3. Asserts service state and config validity
#   4. Re-points mihomo at tinyproxy, restarts, tests the real proxy chain e2e
#   5. Tests the LAN dispatcher with a dummy 172.31.* interface (up -> start, down -> stop)
#   6. Exercises update.sh --action change-ip and --action status
#
# Usage: sudo bash tests/integration-test.sh [path-to-repo]
set -uo pipefail

REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PASS=0; FAIL=0

t() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo -e "  ✓ $desc"; PASS=$((PASS+1))
  else
    echo -e "  ✗ $desc"; FAIL=$((FAIL+1))
  fi
}
tf() {  # expect failure
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo -e "  ✗ $desc (expected failure, got success)"; FAIL=$((FAIL+1))
  else
    echo -e "  ✓ $desc"; PASS=$((PASS+1))
  fi
}

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash tests/integration-test.sh" >&2
  exit 1
fi

echo "── setup: tinyproxy stand-in for the college proxy ──"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq tinyproxy curl iproute2 >/dev/null 2>&1 || true
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q tinyproxy curl iproute >/dev/null 2>&1 || true
fi
command -v tinyproxy >/dev/null 2>&1 || { echo "tinyproxy not available  -  cannot run integration test"; exit 1; }

TP_CONF=/etc/tinyproxy/tinyproxy.conf
mkdir -p "$(dirname "$TP_CONF")"
cat > "$TP_CONF" <<'EOF'
Port 3128
Listen 127.0.0.1
Timeout 600
LogLevel Info
MaxClients 100
Allow 127.0.0.1
BasicAuth edcguest edcguest
EOF
systemctl restart tinyproxy 2>/dev/null || service tinyproxy restart 2>/dev/null || tinyproxy -c "$TP_CONF" &
sleep 1
t "tinyproxy listens on 127.0.0.1:3128" bash -c 'echo > /dev/tcp/127.0.0.1/3128'
# Direct proxy test with auth (bypasses mihomo entirely)
t "tinyproxy honors BasicAuth" curl -fsS --max-time 10 -x http://edcguest:edcguest@127.0.0.1:3128 -o /dev/null https://api.github.com

echo "── install.sh unattended install ──"
UNATTENDED_OUT=$(mktemp)
if bash "$REPO/install.sh" \
     --hostel "New Boys Hostel A Block" \
     --ip 172.31.64.135 \
     --yes --skip-ip --no-tun --no-lan-watch \
     >"$UNATTENDED_OUT" 2>&1; then
  echo "  ✓ install.sh exited 0"; PASS=$((PASS+1))
else
  echo "  ✗ install.sh failed  -  output:"; tail -20 "$UNATTENDED_OUT"; FAIL=$((FAIL+1))
fi
t "mihomo binary on PATH"      bash -c 'command -v mihomo'
t "systemd unit exists"        test -f /etc/systemd/system/mihomo.service || test -f /usr/lib/systemd/system/mihomo.service
t "config generated"           test -f /etc/mihomo/config.yaml
t "config has college proxy"   grep -q "server: 172.31.100.27" /etc/mihomo/config.yaml
t "config tun disabled"        grep -q "enable: false" /etc/mihomo/config.yaml
t "config chmod 600"           test "$(stat -c %a /etc/mihomo/config.yaml 2>/dev/null || stat -f %Lp /etc/mihomo/config.yaml)" = "600"
t "mihomo -t validates config" mihomo -t -d /etc/mihomo
t "mihomo service active"      systemctl is-active mihomo
grep -q "✅" "$UNATTENDED_OUT" && { echo "  ✓ installer reported success"; PASS=$((PASS+1)); } || { echo "  ⚠ installer success marker missing"; }
rm -f "$UNATTENDED_OUT"

echo "── re-point mihomo at tinyproxy and test the real chain ──"
# Same render logic as install.sh, but proxies = tinyproxy. Proves the full
# mihomo -> upstream-http-proxy-with-auth -> internet chain.
PROXIES_BLOCK='  - {name: proxy-1, type: http, server: 127.0.0.1, port: 3128, username: edcguest, password: edcguest}'
python3 - "$REPO/config.template.yaml" /etc/mihomo/config.yaml "$PROXIES_BLOCK" <<'PYEOF'
import sys
template_path, out_path, proxies_block = sys.argv[1:4]
with open(template_path) as f:
    t = f.read()
t = t.replace("{{PROXY_ENTRIES}}", proxies_block)
t = t.replace("{{PROXY_NAMES}}", "proxy-1")
t = t.replace("{{TUN_ENABLE}}", "false")
with open(out_path, "w") as f:
    f.write(t)
PYEOF
chmod 600 /etc/mihomo/config.yaml
t "mihomo -t accepts tinyproxy config" mihomo -t -d /etc/mihomo
systemctl restart mihomo
sleep 2
t "mihomo active after restart"        systemctl is-active mihomo
E2E_CODE=$(curl -sS --max-time 15 -x http://127.0.0.1:7890 -o /dev/null -w '%{http_code}' https://api.github.com 2>/dev/null || echo 000)
echo "  e2e via mihomo:7890 -> tinyproxy:3128 -> internet: HTTP $E2E_CODE"
t "e2e returns HTTP 200"               test "$E2E_CODE" = "200"

echo "── LAN dispatcher logic (dummy campus interface) ──"
# Save existing default routes so we can restore them exactly afterwards
ORIG_ROUTES=$(ip route show default)
ip link add dummy0 type dummy 2>/dev/null || true
ip addr add 172.31.99.1/24 dev dummy0 2>/dev/null || true
ip link set dummy0 up
# Make dummy0 the preferred campus default route (lower metric wins)
ip route replace default via 172.31.99.254 dev dummy0 metric 50 2>/dev/null || true

systemctl stop mihomo 2>/dev/null || true
sleep 1
bash "$REPO/dispatcher/90-mihomo-lan" dummy0 up
sleep 2
t "dispatcher 'up' starts mihomo"      systemctl is-active mihomo

ip route del default dev dummy0 metric 50 2>/dev/null || true
ip link set dummy0 down
bash "$REPO/dispatcher/90-mihomo-lan" dummy0 down
sleep 2
tf "dispatcher 'down' stops mihomo"    systemctl is-active mihomo

ip link del dummy0 2>/dev/null || true
# Restore the original default routes
if [[ -n "$ORIG_ROUTES" ]]; then
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    ip route add $r metric 100 2>/dev/null || true
  done <<< "$ORIG_ROUTES"
fi
# bring mihomo back for the update.sh tests
systemctl start mihomo 2>/dev/null || true

echo "── update.sh actions ──"
t "status action exits 0"    bash "$REPO/update.sh" --action status
t "change-ip regenerates"    bash "$REPO/update.sh" --action change-ip \
                               --hostel "Post Graduate Hostel" \
                               --ip 172.31.144.50 --yes --force
t "config now has PG proxy"  grep -q "server: 172.31.100.25" /etc/mihomo/config.yaml
t "mihomo still active"      systemctl is-active mihomo

echo
if [[ $FAIL -eq 0 ]]; then
  echo "INTEGRATION: ALL $PASS TESTS PASSED"
  exit 0
else
  echo "INTEGRATION: PASS=$PASS FAIL=$FAIL"
  exit 1
fi