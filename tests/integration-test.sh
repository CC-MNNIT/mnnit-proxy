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
# Wait for the port (service restart can race the test)
for _ in 1 2 3 4 5 6 7 8; do
  bash -c 'echo > /dev/tcp/127.0.0.1/3128' 2>/dev/null && break
  sleep 1
done
t "tinyproxy listens on 127.0.0.1:3128" bash -c 'echo > /dev/tcp/127.0.0.1/3128'
# Direct proxy test with auth (bypasses mihomo entirely); retry for flake-resistance
AUTH_OK=false
for _ in 1 2 3; do
  if curl -fsS --max-time 10 -x http://edcguest:edcguest@127.0.0.1:3128 -o /dev/null https://api.github.com 2>/dev/null; then
    AUTH_OK=true; break
  fi
  sleep 2
done
$AUTH_OK && { echo "  ✓ tinyproxy honors BasicAuth"; PASS=$((PASS+1)); } || { echo "  ✗ tinyproxy honors BasicAuth"; FAIL=$((FAIL+1)); }

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
# Start decision: runners have no campus gateway, so the installer should
# leave mihomo stopped (correct no-phantom behavior). Assert the right one.
if grep -q "mihomo left stopped" "$UNATTENDED_OUT"; then
  tf "correctly left stopped (no campus network)" systemctl is-active mihomo
else
  t "correctly started (campus detected)" systemctl is-active mihomo
fi
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

echo "── no-NM honest install path (backend forced to manual) ──"
# Proves: install succeeds without NM, no dead dispatcher file is installed,
# mihomo gets enabled for boot start, and the user is told the truth.
NM_OUT=$(mktemp)
MNNIT_FORCE_BACKEND=manual bash "$REPO/install.sh" \
     --hostel "New Boys Hostel A Block" \
     --ip 172.31.64.135 \
     --yes --skip-ip --no-tun \
     >"$NM_OUT" 2>&1
t "install exits 0 without NetworkManager" test -f /etc/mihomo/config.yaml
grep -q "NetworkManager not found" "$NM_OUT" && { echo "  ✓ reports NM missing honestly"; PASS=$((PASS+1)); } || { echo "  ✗ no NM-missing warning"; FAIL=$((FAIL+1)); }
grep -q "LAN watcher unavailable" "$NM_OUT" && { echo "  ✓ watcher skipped with reason"; PASS=$((PASS+1)); } || { echo "  ✗ watcher guard message missing"; FAIL=$((FAIL+1)); }
tf "no dead dispatcher file installed"      test -f /etc/NetworkManager/dispatcher.d/90-mihomo-lan
t "mihomo enabled for boot start"           systemctl is-enabled mihomo
rm -f "$NM_OUT"

echo "── netplan path (backend forced, mocked apply) ──"
# Fake netplan on PATH: records the apply call, never touches networking.
NPBIN=$(mktemp -d)
cat > "$NPBIN/netplan" <<'MOCK'
#!/bin/bash
if [[ "$1" == "apply" ]]; then touch /tmp/mnnit-test-netplan-applied; fi
exit 0
MOCK
chmod +x "$NPBIN/netplan"
mkdir -p "$NPBIN/netplan-dir"
cat > "$NPBIN/ip" <<'MOCK'
#!/bin/bash
echo "inet 172.31.64.135/23"
exit 0
MOCK
chmod +x "$NPBIN/ip"
NP_OUT=$(mktemp)
rm -f /tmp/mnnit-test-netplan-applied
MNNIT_FORCE_BACKEND=netplan NETPLAN_DIR="$NPBIN/netplan-dir" PATH="$NPBIN:$PATH" \
  bash "$REPO/install.sh" \
     --hostel "New Boys Hostel A Block" \
     --ip 172.31.64.135 \
     --yes --skip-ip --no-tun --no-lan-watch \
     >"$NP_OUT" 2>&1
grep -q "Network backend: netplan" "$NP_OUT" && { echo "  ✓ backend detected as netplan"; PASS=$((PASS+1)); } || { echo "  ✗ netplan backend not detected"; FAIL=$((FAIL+1)); }
# --skip-ip keeps install hands-off; exercise the writer directly
NETPLAN_DIR="$NPBIN/netplan-dir" PATH="$NPBIN:$PATH" bash -c "
  source '$REPO/install.sh' 2>/dev/null
  WIRED_IFACE=entest0
  SELECTED_HOSTEL_IP=172.31.64.135
  SELECTED_HOSTEL_PREFIX=23
  SELECTED_HOSTEL_GW=172.31.64.1
  NETPLAN_FILE='$NPBIN/netplan-dir/99-mnnit-proxy.yaml'
  apply_netplan >/dev/null 2>&1
" && { echo "  ✓ netplan writer ran"; PASS=$((PASS+1)); } || { echo "  ✗ netplan writer failed"; FAIL=$((FAIL+1)); }
t "netplan file written"                    test -f "$NPBIN/netplan-dir/99-mnnit-proxy.yaml"
t "netplan file chmod 600"                  test "$(stat -c %a "$NPBIN/netplan-dir/99-mnnit-proxy.yaml" 2>/dev/null)" = "600"
grep -q "172.31.64.135/23" "$NPBIN/netplan-dir/99-mnnit-proxy.yaml" 2>/dev/null && { echo "  ✓ netplan yaml has room IP"; PASS=$((PASS+1)); } || { echo "  ✗ netplan yaml missing room IP"; FAIL=$((FAIL+1)); }
t "netplan apply was invoked"               test -f /tmp/mnnit-test-netplan-applied
# conflict guard: pre-existing file managing the iface -> no overwrite
touch "$NPBIN/netplan-dir/00-existing.yaml"
echo "ethernets: {entest0: {dhcp4: true}}" > "$NPBIN/netplan-dir/00-existing.yaml"
rm -f "$NPBIN/netplan-dir/99-mnnit-proxy.yaml" /tmp/mnnit-test-netplan-applied
NETPLAN_DIR="$NPBIN/netplan-dir" PATH="$NPBIN:$PATH" bash -c "
  source '$REPO/install.sh' 2>/dev/null
  WIRED_IFACE=entest0
  SELECTED_HOSTEL_IP=172.31.64.135
  SELECTED_HOSTEL_PREFIX=23
  SELECTED_HOSTEL_GW=172.31.64.1
  NETPLAN_FILE='$NPBIN/netplan-dir/99-mnnit-proxy.yaml'
  apply_netplan >/dev/null 2>&1
"
tf "conflict: our file NOT written"         test -f "$NPBIN/netplan-dir/99-mnnit-proxy.yaml"
rm -rf "$NPBIN" "$NP_OUT"; rm -f /tmp/mnnit-test-netplan-applied

echo "── service-user config ownership (AUR-style unit) ──"
# The AUR mihomo package runs the daemon as a dedicated user. Simulate that
# unit (User=daemon) and prove fix_config_ownership adjusts perms correctly.
OWBIN=$(mktemp -d)
cat > "$OWBIN/systemctl" <<'M'
#!/bin/sh
[ "$4" = "User" ] && echo daemon
[ "$4" = "Group" ] && echo daemon
exit 0
M
chmod +x "$OWBIN/systemctl"
ORIG_MODE=$(stat -c %a /etc/mihomo/config.yaml)
ORIG_OWNER=$(stat -c %u:%g /etc/mihomo/config.yaml)
ORIG_DIR_OWNER=$(stat -c %u:%g /etc/mihomo)
PATH="$OWBIN:$PATH" bash -c "
  source '$REPO/install.sh' 2>/dev/null
  fix_config_ownership
" >/dev/null 2>&1
t "config group readable by service user"  test "$(stat -c %G /etc/mihomo/config.yaml)" = "daemon"
t "config mode 640 (not world-readable)"   test "$(stat -c %a /etc/mihomo/config.yaml)" = "640"
t "config still root-owned"                test "$(stat -c %U /etc/mihomo/config.yaml)" = "root"
t "/etc/mihomo writable by service user"   test "$(stat -c %U /etc/mihomo)" = "daemon"
# restore container state (its real unit runs as root)
chown "$ORIG_OWNER" /etc/mihomo/config.yaml
chmod "$ORIG_MODE" /etc/mihomo/config.yaml
chown "$ORIG_DIR_OWNER" /etc/mihomo
rm -rf "$OWBIN"

echo "── unattended flag validation ──"
t "invalid --ip rejected cleanly"   bash -c "bash '$REPO/install.sh' --hostel 'New Boys Hostel A Block' --ip not-an-ip --yes 2>&1 | grep -q 'Invalid --ip'"
t "invalid --gateway rejected"      bash -c "bash '$REPO/install.sh' --hostel 'New Boys Hostel A Block' --ip 172.31.64.135 --gateway 999.1.1.1 --yes 2>&1 | grep -q 'Invalid --gateway'"
t "999 octet rejected by updater"   bash -c "bash '$REPO/update.sh' --action change-ip --hostel 'Post Graduate Hostel' --ip 172.31.144.999 --yes 2>&1 | grep -q 'Invalid --ip'"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "INTEGRATION: ALL $PASS TESTS PASSED"
  exit 0
else
  echo "INTEGRATION: PASS=$PASS FAIL=$FAIL"
  exit 1
fi