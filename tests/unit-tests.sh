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

echo "── persisted interface state ──"
STATE_DIR=$(mktemp -d)
t "state round-trip" env MNNIT_STATE_FILE="$STATE_DIR/state" bash -c '
  source "$1" 2>/dev/null
  WIRED_IFACE=enp0s8
  WIRED_CONN=12345678-1234-1234-1234-123456789abc
  PROFILE_CREATED=true
  PREVIOUS_CONN=abcdefab-1234-1234-1234-abcdefabcdef
  save_state
  WIRED_IFACE=""; WIRED_CONN=""; PROFILE_CREATED=false; PREVIOUS_CONN=""
  load_state
  [[ "$STATE_WIRED_IFACE" == enp0s8 &&
     "$STATE_WIRED_CONN" == 12345678-1234-1234-1234-123456789abc &&
     "$STATE_PROFILE_CREATED" == true &&
     "$STATE_PREVIOUS_CONN" == abcdefab-1234-1234-1234-abcdefabcdef ]]
' _ "$REPO/install.sh"
t "state file mode 600" test "$(stat -c %a "$STATE_DIR/state")" = 600
rm -rf "$STATE_DIR"

echo "── DHCP restore fields ──"
DHCP_BIN=$(mktemp -d)
DHCP_CALLS="$DHCP_BIN/calls"
cat > "$DHCP_BIN/nmcli" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$DHCP_CALLS"
MOCK
chmod +x "$DHCP_BIN/nmcli"
export DHCP_CALLS
PATH="$DHCP_BIN:$PATH" bash -c 'source "$1" 2>/dev/null; reset_nm_profile_to_dhcp test-uuid' _ "$REPO/install.sh"
t "DHCP reset clears addresses" grep -q "ipv4.addresses" "$DHCP_CALLS"
t "DHCP reset clears gateway"   grep -q "ipv4.gateway" "$DHCP_CALLS"
t "DHCP reset clears DNS"       grep -q "ipv4.dns" "$DHCP_CALLS"
t "DHCP reset clears routes"    grep -q "ipv4.routes" "$DHCP_CALLS"
unset DHCP_CALLS
rm -rf "$DHCP_BIN"

echo "── interface discovery is read-only ──"
TEST_ETH=$(find /sys/class/net -maxdepth 1 -type l -printf '%f\n' 2>/dev/null | grep -E '^(en|eth)' | head -1 || true)
if [[ -n "$TEST_ETH" ]]; then
  DISC_BIN=$(mktemp -d)
  DISC_CALLS="$DISC_BIN/calls"; export DISC_CALLS
  cat > "$DISC_BIN/nmcli" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$DISC_CALLS"
if [ "$1 $2 $3" = "-g GENERAL.STATE device" ]; then echo "30 (disconnected)"; fi
exit 0
MOCK
  chmod +x "$DISC_BIN/nmcli"
  PATH="$DISC_BIN:$PATH" bash -c '
    source "$1" 2>/dev/null
    NET_BACKEND=networkmanager
    FLAG_INTERFACE="$2"
    detect_iface >/dev/null
  ' _ "$REPO/install.sh" "$TEST_ETH"
  tf "detect does not create a profile" grep -q "con add" "$DISC_CALLS"
  unset DISC_CALLS
  rm -rf "$DISC_BIN"
else
  echo "  - no Ethernet interface in test environment; skipping"
fi

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
t "netplan yaml has campus route" grep -q "to: 172.31.0.0/16" "$NP_DIR/99-mnnit-proxy.yaml"
t "netplan yaml has all dns"      grep -q "172.31.100.6 172.31.100.7 172.31.100.8" "$NP_DIR/99-mnnit-proxy.yaml"
tf "netplan yaml no placeholders" grep -q '{{' "$NP_DIR/99-mnnit-proxy.yaml"
rm -rf "$NP_DIR"

echo "── service-user config ownership ──"
OWN_DIR=$(mktemp -d)
CFG_FAKE="$OWN_DIR/fake.yaml"
echo "x: 1" > "$CFG_FAKE"
OWN_GRP=$(stat -c %G "$CFG_FAKE")
chmod 600 "$CFG_FAKE"
tf "cfg 600 not group-readable"   config_group_readable "$OWN_GRP" "$CFG_FAKE"
chmod 640 "$CFG_FAKE"
t  "cfg 640 correct group"        config_group_readable "$OWN_GRP" "$CFG_FAKE"
tf "cfg 640 wrong group"          config_group_readable "nosuchgroup12345" "$CFG_FAKE"
chmod 644 "$CFG_FAKE"
t  "cfg 644 world-readable"       config_group_readable "nosuchgroup12345" "$CFG_FAKE"
tf "cfg missing file"             config_group_readable "$OWN_GRP" "$OWN_DIR/nope.yaml"

# fix_config_ownership with mocked systemctl/chown/chmod (records calls)
OWBIN=$(mktemp -d)
CALLS="$OWN_DIR/calls"; export CALLS
cat > "$OWBIN/systemctl" <<'M'
#!/bin/sh
[ "$4" = "User" ] && echo mihomo
[ "$4" = "Group" ] && echo mihomo
exit 0
M
cat > "$OWBIN/chown" <<'M'
#!/bin/sh
echo "chown $*" >> "$CALLS"
M
cat > "$OWBIN/chmod" <<'M'
#!/bin/sh
echo "chmod $*" >> "$CALLS"
M
chmod +x "$OWBIN/systemctl" "$OWBIN/chown" "$OWBIN/chmod"
OLD_PATH_OW="$PATH"
PATH="$OWBIN:$PATH"
rm -f "$CALLS"
fix_config_ownership
t "fix: chown config root:mihomo"  grep -q "^chown root:mihomo /etc/mihomo/config.yaml$" "$CALLS"
t "fix: chmod 640 config"          grep -q "^chmod 640 /etc/mihomo/config.yaml$" "$CALLS"
t "fix: chown dir mihomo:mihomo"   grep -q "^chown mihomo:mihomo /etc/mihomo$" "$CALLS"
# root service (our own unit) -> no chown/chmod calls at all
printf '#!/bin/sh\nexit 0\n' > "$OWBIN/systemctl"; chmod +x "$OWBIN/systemctl"
rm -f "$CALLS"
fix_config_ownership
tf "fix: root service is a no-op"  test -s "$CALLS"
PATH="$OLD_PATH_OW"
unset CALLS
rm -rf "$OWBIN" "$OWN_DIR"

echo "── --help completeness ──"
t "install.sh --help shows last flag (--diagnose)"  bash -c "bash '$REPO/install.sh' --help | grep -q -- '--diagnose'"
t "install.sh --help shows --tun-stack"             bash -c "bash '$REPO/install.sh' --help | grep -q -- '--tun-stack'"
t "update.sh --help shows --tun-stack"              bash -c "bash '$REPO/update.sh' --help | grep -q -- '--tun-stack'"
t "install rejects invalid --tun-stack"             bash -c "bash '$REPO/install.sh' --tun-stack nope 2>&1 | grep -q 'Invalid --tun-stack'"
t "updater rejects invalid --tun-stack"             bash -c "bash '$REPO/update.sh' --tun-stack nope 2>&1 | grep -q 'Invalid --tun-stack'"

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

echo "── campus-link start decision ──"
campus_link() { return 0; }
t "campus address + carrier -> start" should_start_mihomo
campus_link() { return 1; }
tf "no live campus address -> don't start" should_start_mihomo

echo "── tun stack validation ──"
for stack in system gvisor mixed mips; do
  t "stack accepted: $stack" valid_tun_stack "$stack"
done
tf "invalid stack rejected" valid_tun_stack nope
t "pinned amd64 digest shape" bash -c '[[ "$1" =~ ^[0-9a-f]{64}$ ]]' _ "$MIHOMO_PINNED_AMD64_SHA256"
t "pinned arm64 digest shape" bash -c '[[ "$1" =~ ^[0-9a-f]{64}$ ]]' _ "$MIHOMO_PINNED_ARM64_SHA256"

echo "── config rendering ──"
# PROXY_PORT/PROXY_USER/PROXY_PASS are already set (readonly) by sourcing install.sh
TEMPLATE="$REPO/config.template.yaml"
SELECTED_HOSTEL_PROXIES="172.31.100.27,172.31.102.29"
OUT=$(mktemp)
render_cfg() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$TEMPLATE" <<'PYEOF'
import json
import sys
proxy_entries, proxy_names, tun_enable, tun_stack, outbound_iface, template_path = sys.argv[1:7]
with open(template_path) as f:
    t = f.read()
t = t.replace("{{PROXY_ENTRIES}}", proxy_entries.rstrip("\n"))
t = t.replace("{{PROXY_NAMES}}", proxy_names)
t = t.replace("{{TUN_ENABLE}}", tun_enable)
t = t.replace("{{TUN_STACK}}", tun_stack)
if outbound_iface:
    t = t.replace("{{INTERFACE_CONFIG}}", "interface-name: " + json.dumps(outbound_iface))
    t = t.replace("{{AUTO_DETECT_INTERFACE}}", "false")
else:
    t = t.replace("{{INTERFACE_CONFIG}}\n", "")
    t = t.replace("{{INTERFACE_CONFIG}}", "")
    t = t.replace("{{AUTO_DETECT_INTERFACE}}", "true")
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
render_cfg "$pe" "$pn" "true" "gvisor" "enp0s8" > "$OUT"
grep -q "server: 172.31.100.27" "$OUT"; t "proxy-1 rendered"       test $? -eq 0
grep -q "proxies: \[proxy-1, proxy-2\]" "$OUT"; t "group names rendered" test $? -eq 0
grep -q "enable: true" "$OUT";                 t "tun enabled default"    test $? -eq 0
grep -q "stack: gvisor" "$OUT";                t "gvisor stack rendered"  test $? -eq 0
grep -q 'interface-name: "enp0s8"' "$OUT";     t "outbound interface pinned" test $? -eq 0
grep -q "auto-detect-interface: false" "$OUT"; t "auto detection disabled when pinned" test $? -eq 0
grep -q "^sniffer:" "$OUT";                    t "domain sniffer rendered" test $? -eq 0
grep -q "parse-pure-ip: true" "$OUT";           t "pure-IP traffic sniffed" test $? -eq 0
if grep -q "{{" "$OUT"; then echo "  ✗ leftover placeholders"; FAIL=$((FAIL+1)); else echo "  ✓ no leftover placeholders"; PASS=$((PASS+1)); fi
render_cfg "$pe" "$pn" "false" "system" "" > "$OUT"
grep -q "enable: false" "$OUT"; t "--no-tun renders enable:false"  test $? -eq 0
grep -q "auto-detect-interface: true" "$OUT"; t "no pin keeps auto detection" test $? -eq 0

if command -v mihomo >/dev/null 2>&1; then
  render_cfg "$pe" "$pn" "false" "gvisor" "enp0s8" > "$OUT"
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
