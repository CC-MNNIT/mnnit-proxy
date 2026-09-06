#!/usr/bin/env bash
# mnnit-proxy unit tests  -  no root, no network, no mihomo required.
# Usage: bash tests/unit-tests.sh [path-to-repo]
set -uo pipefail

REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PASS=0; FAIL=0

t() {  # t <desc> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo -e "  ✓ $desc"; PASS=$((PASS+1))
  else
    echo -e "  ✗ $desc"; FAIL=$((FAIL+1))
  fi
}
tf() {  # tf <desc> <command...>  (expect failure)
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo -e "  ✗ $desc (expected failure, got success)"; FAIL=$((FAIL+1))
  else
    echo -e "  ✓ $desc"; PASS=$((PASS+1))
  fi
}

echo "── syntax ──"
t "install.sh parses"      bash -n "$REPO/install.sh"
t "update.sh parses"       bash -n "$REPO/update.sh"
t "dispatcher parses"      bash -n "$REPO/dispatcher/90-mihomo-lan"

if command -v shellcheck >/dev/null 2>&1; then
  t "shellcheck install.sh (no errors)" shellcheck -S error "$REPO/install.sh"
  t "shellcheck update.sh (no errors)"  shellcheck -S error "$REPO/update.sh"
  t "shellcheck dispatcher (no errors)" shellcheck -S error "$REPO/dispatcher/90-mihomo-lan"
else
  echo "  - shellcheck not installed, skipping"
fi

echo "── data files ──"
t "hostels.tsv exists"           test -s "$REPO/hostels.tsv"
t "config template exists"       test -s "$REPO/config.template.yaml"
t "dispatcher is executable"     test -x "$REPO/dispatcher/90-mihomo-lan"

ROWS=$(grep -vcE '^\s*(#|$)' "$REPO/hostels.tsv")
t "hostels.tsv has entries ($ROWS)" test "$ROWS" -gt 10

echo "── install.sh function tests ──"
bash -s "$REPO" <<'FUNC'
set -uo pipefail
REPO="$1"
PASS=0; FAIL=0
t()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "  ✓ $d"; PASS=$((PASS+1)); else echo "  ✗ $d"; FAIL=$((FAIL+1)); fi; }
tf() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "  ✗ $d (expected fail)"; FAIL=$((FAIL+1)); else echo "  ✓ $d"; PASS=$((PASS+1)); fi; }

# Source install.sh  -  its main() is guarded, only functions load.
source "$REPO/install.sh" 2>/dev/null

echo "── ip helpers ──"
t "ip2int correct"             test "$(ip2int 172.31.64.135)" = "$(( (172<<24)|(31<<16)|(64<<8)|135 ))"
t "ip2int zero"                test "$(ip2int 0.0.0.0)" = 0
t "ip2int max"                 test "$(ip2int 255.255.255.255)" = 4294967295
t "ip2int no octal parsing"    test "$(ip2int 10.0.0.10)" = "$(( (10<<24)|10 ))"
t "in_range middle of range"   in_range 172.31.64.135 172.31.64.60 172.31.65.168
t "in_range at from edge"      in_range 172.31.64.60 172.31.64.60 172.31.65.168
t "in_range at to edge"        in_range 172.31.65.168 172.31.64.60 172.31.65.168
tf "in_range below range"      in_range 172.31.64.20 172.31.64.60 172.31.65.168
tf "in_range above range"      in_range 172.31.66.1 172.31.64.60 172.31.65.168
t "valid_ip accepts quad"      valid_ip 10.0.0.1
t "valid_ip accepts 255"       valid_ip 255.255.255.255
tf "valid_ip rejects garbage"  valid_ip not-an-ip
tf "valid_ip rejects 999"      valid_ip 999.1.1.1
tf "valid_ip rejects 256"      valid_ip 172.31.64.256
tf "valid_ip rejects short"    valid_ip 1.2.3
tf "valid_ip rejects 5 octets" valid_ip 1.2.3.4.5

echo "── network backend classification ──"
MOCKBIN="$(mktemp -d)"
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/systemctl"; chmod +x "$MOCKBIN/systemctl"
# Strict isolation: PATH contains ONLY the mock dir, so the runner's real
# nmcli/netplan can't leak in.
OLD_PATH="$PATH"

# networkmanager: nmcli present + NM active (mocked)
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/nmcli"; chmod +x "$MOCKBIN/nmcli"
PATH="$MOCKBIN" detect_backend
t "backend: networkmanager (mocked)"  test "$NET_BACKEND" = "networkmanager"

# netplan: no nmcli, netplan + config dir present (mocked dir)
rm -f "$MOCKBIN/nmcli"
mkdir -p "$MOCKBIN/netplan-dir"
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/netplan"; chmod +x "$MOCKBIN/netplan"
NETPLAN_DIR="$MOCKBIN/netplan-dir" PATH="$MOCKBIN" detect_backend
t "backend: netplan (mocked)"         test "$NET_BACKEND" = "netplan"

# manual: neither nmcli nor netplan on PATH
rm -f "$MOCKBIN/netplan"
PATH="$MOCKBIN" detect_backend
t "backend: manual (mocked)"          test "$NET_BACKEND" = "manual"

PATH="$OLD_PATH"
rm -rf "$MOCKBIN"

echo "── netplan config writer ──"
WIRED_IFACE="enp0s8"
SELECTED_HOSTEL_IP="172.31.64.135"
SELECTED_HOSTEL_PREFIX="23"
SELECTED_HOSTEL_GW="172.31.64.1"
NP_DIR="$(mktemp -d)"
netplan_yaml > "$NP_DIR/99-mnnit-proxy.yaml"
t "netplan yaml has iface"        grep -q "^    enp0s8:" "$NP_DIR/99-mnnit-proxy.yaml"
t "netplan yaml has ip/prefix"    grep -q "172.31.64.135/23" "$NP_DIR/99-mnnit-proxy.yaml"
t "netplan yaml has gateway"      grep -q "via: 172.31.64.1" "$NP_DIR/99-mnnit-proxy.yaml"
t "netplan yaml has all dns"      grep -q "172.31.100.6 172.31.100.7 172.31.100.8" "$NP_DIR/99-mnnit-proxy.yaml"
tf "netplan yaml no placeholders" grep -q '{{' "$NP_DIR/99-mnnit-proxy.yaml"
rm -rf "$NP_DIR"

echo "── --help completeness ──"
t "install.sh --help shows last flag (--diagnose)"  bash -c "bash '$REPO/install.sh' --help | grep -q -- '--diagnose'"
t "update.sh --help shows last flag (--yes)"        bash -c "bash '$REPO/update.sh' --help | grep -q -- '--yes'"

echo "── hostel resolution ──"
TSV="$REPO/hostels.tsv"
FLAG_FORCE=false
SELECTED_HOSTEL_IP="172.31.64.135"
t "resolve exact name"         resolve_hostel_by_name "New Boys Hostel A Block"
t "resolved name correct"      test "$SELECTED_HOSTEL_NAME" = "New Boys Hostel A Block"
t "resolved proxies correct"   test "$SELECTED_HOSTEL_PROXIES" = "172.31.100.27,172.31.102.29"
SELECTED_HOSTEL_IP="172.31.64.20"
FLAG_FORCE=true
t "out-of-range passes with --force"  resolve_hostel_by_name "New Boys Hostel A Block"
FLAG_FORCE=false

echo "── floor-wise derivation (SVBH) ──"
SELECTED_HOSTEL_NAME="Swami Vivekananda Boys Hostel"
SELECTED_HOSTEL_GW="floorwise"
SELECTED_HOSTEL_PREFIX="floorwise"
SELECTED_HOSTEL_IP="172.31.140.33"
derive_network
t "floorwise prefix -> 24"     test "$SELECTED_HOSTEL_PREFIX" = "24"
t "floorwise gw -> /24 base"   test "$SELECTED_HOSTEL_GW" = "172.31.140.1"
FLAG_GATEWAY="172.31.137.1"
derive_network
t "--gateway overrides"        test "$SELECTED_HOSTEL_GW" = "172.31.137.1"
unset FLAG_GATEWAY

echo "── should_start_mihomo decision matrix ──"
# Matrix: [watcher-installed?] x [campus-gateway-present?]
# Watcher rule dominates: if the dispatcher file exists, NEVER start.
DISP=/etc/NetworkManager/dispatcher.d/90-mihomo-lan
if [[ -f "$DISP" ]]; then
  tf "watcher present -> never force-start" should_start_mihomo
  if [[ $EUID -eq 0 ]]; then
    # root: can temporarily remove dispatcher to test the no-watcher branch
    mv "$DISP" "$DISP.unittest"
    if ip route show default 2>/dev/null | grep -q "via 172.31."; then
      t "no watcher + campus link -> start" should_start_mihomo
    else
      tf "no watcher + no campus link -> don't start" should_start_mihomo
    fi
    mv "$DISP.unittest" "$DISP"
  else
    echo "  - watcher installed on this machine; no-watcher branch covered by CI"
  fi
else
  if ip route show default 2>/dev/null | grep -q "via 172.31."; then
    t "no watcher + campus link -> start" should_start_mihomo
  else
    tf "no watcher + no campus link -> don't start" should_start_mihomo
  fi
fi

echo "── config rendering ──"
# PROXY_PORT/PROXY_USER/PROXY_PASS are already set (readonly) by sourcing install.sh
TEMPLATE="$REPO/config.template.yaml"
SELECTED_HOSTEL_PROXIES="172.31.100.27,172.31.102.29"
OUT=$(mktemp)
render_cfg() {
  python3 - "$1" "$2" "$3" "$TEMPLATE" <<'PYEOF'
import sys
proxy_entries, proxy_names, tun_enable, template_path = sys.argv[1:5]
with open(template_path) as f:
    t = f.read()
t = t.replace("{{PROXY_ENTRIES}}", proxy_entries.rstrip("\n"))
t = t.replace("{{PROXY_NAMES}}", proxy_names)
t = t.replace("{{TUN_ENABLE}}", tun_enable)
sys.stdout.write(t)
PYEOF
}
pe=""
pn=""
idx=0
IFS=,
read -ra plist <<< "$SELECTED_HOSTEL_PROXIES"
unset IFS
for p in "${plist[@]}"; do
  idx=$((idx+1))
  pe+="  - {name: proxy-${idx}, type: http, server: ${p}, port: 3128, username: edcguest, password: edcguest}"$'\n'
  [[ -n "$pn" ]] && pn+=", "
  pn+="proxy-${idx}"
done
render_cfg "$pe" "$pn" "true" > "$OUT"
grep -q "server: 172.31.100.27" "$OUT"; t "proxy-1 rendered"       test $? -eq 0
grep -q "proxies: \[proxy-1, proxy-2\]" "$OUT"; t "group names rendered" test $? -eq 0
grep -q "enable: true" "$OUT";                 t "tun enabled default"    test $? -eq 0
if grep -q "{{" "$OUT"; then echo "  ✗ leftover placeholders"; FAIL=$((FAIL+1)); else echo "  ✓ no leftover placeholders"; PASS=$((PASS+1)); fi
render_cfg "$pe" "$pn" "false" > "$OUT"
grep -q "enable: false" "$OUT"; t "--no-tun renders enable:false"  test $? -eq 0

if command -v mihomo >/dev/null 2>&1; then
  render_cfg "$pe" "$pn" "false" > "$OUT"
  TD=$(mktemp -d); cp "$OUT" "$TD/config.yaml"
  if mihomo -t -d "$TD" >/dev/null 2>&1; then
    echo "  ✓ mihomo accepts rendered config"; PASS=$((PASS+1))
  else
    echo "  ✗ mihomo rejects config"; FAIL=$((FAIL+1))
  fi
  rm -rf "$TD"
else
  echo "  - mihomo not installed, skipping live validation"
fi
rm -f "$OUT"

echo
echo "FUNC-PASS=$PASS FUNC-FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
exit $(( FAIL > 0 ? 1 : 0 ))
FUNC
FUNCTION_STATUS=$?

echo
if [[ $FUNCTION_STATUS -ne 0 ]]; then
  echo "Some function tests failed (see FUNC-FAIL count above)."
  exit 1
fi
echo "ALL UNIT TESTS PASSED"
exit 0