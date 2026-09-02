#!/usr/bin/env bash
# mnnit-proxy updater  -  change hostel/IP, restore DHCP, or show status.
# Does NOT reinstall mihomo. Requires an existing install.
# Usage:  sudo bash update.sh
set -Eeuo pipefail

readonly VERSION="1.0.0"
readonly PROXY_PORT=3128
readonly PROXY_USER="edcguest"
readonly PROXY_PASS="edcguest"
readonly DNS_SRV="172.31.100.6 172.31.100.7 172.31.100.8"
readonly DNS_SRV_LIST="172.31.100.6,172.31.100.7,172.31.100.8"

# Data files  -  local dir first, then /opt copy (installed by install.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || pwd)"
if [[ -f "$SCRIPT_DIR/hostels.tsv" && -f "$SCRIPT_DIR/config.template.yaml" ]]; then
  TSV="$SCRIPT_DIR/hostels.tsv"
  TEMPLATE="$SCRIPT_DIR/config.template.yaml"
elif [[ -f /opt/mnnit-proxy/hostels.tsv && -f /opt/mnnit-proxy/config.template.yaml ]]; then
  TSV="/opt/mnnit-proxy/hostels.tsv"
  TEMPLATE="/opt/mnnit-proxy/config.template.yaml"
else
  echo "mnnit-proxy is not installed (no data files found)." >&2
  echo "Run install.sh first:  curl -fsSL <URL>/install.sh | sudo bash" >&2
  exit 1
fi

WIRED_IFACE=""
WIRED_CONN=""
SELECTED_HOSTEL_NAME=""
SELECTED_HOSTEL_IP=""
SELECTED_HOSTEL_GW=""
SELECTED_HOSTEL_PREFIX=""
SELECTED_HOSTEL_PROXIES=""

if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
else
  R=; G=; Y=; C=; B=; N=
fi
log()  { echo -e "${B}${C}[*]${N} $*"; }
ok()   { echo -e " ${G}${B}✓${N} $*"; }
warn() { echo -e " ${Y}${B}⚠${N} $*"; }
fail() { echo -e " ${R}${B}✗${N} $*"; }
die()  { fail "$*"; exit 1; }

__tty_read() {
  if [[ -t 0 ]]; then read -r "$@"
  else read -r "$@" < /dev/tty
  fi
}
ask() {
  local prompt="$1" default="${2:-}" reply
  echo -en "${B}${prompt}${N} " >&2
  __tty_read reply
  [[ -z "$reply" && -n "$default" ]] && reply="$default"
  echo "$reply"
}
confirm() {
  local prompt="$1" default="${2:-y}" reply
  local dfl="${default^^}"
  echo -en "${B}${prompt}${N} [${dfl}] " >&2
  __tty_read reply
  reply="${reply:-$default}"
  [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

ip2int() {
  local IFS=. a b c d
  read -r a b c d <<< "$1"
  echo "$((a<<24 | b<<16 | c<<8 | d))"
}
in_range() {
  local ip="$1" from="$2" to="$3"
  local ip_i from_i to_i
  ip_i=$(ip2int "$ip")
  from_i=$(ip2int "$from")
  to_i=$(ip2int "$to")
  ((ip_i >= from_i && ip_i <= to_i))
}

detect_iface() {
  local ifaces
  ifaces=($(ls /sys/class/net 2>/dev/null | grep -E '^(en|eth)' || true))
  if [[ ${#ifaces[@]} -eq 0 ]]; then
    warn "No ethernet interface found."
    return 1
  fi
  local i iface=""
  for i in "${ifaces[@]}"; do
    if [[ "$(cat /sys/class/net/$i/carrier 2>/dev/null)" == "1" ]]; then
      iface="$i"; break
    fi
  done
  iface="${iface:-${ifaces[0]}}"
  WIRED_IFACE="$iface"
  WIRED_CONN=$(nmcli -g GENERAL.CONNECTION device show "$WIRED_IFACE" 2>/dev/null | head -1)
  if [[ -z "$WIRED_CONN" ]]; then
    WIRED_CONN=$(nmcli -t -f NAME,TYPE con show 2>/dev/null | grep ':802-3-ethernet' | cut -d: -f1 | head -1)
  fi
  ok "Interface: $WIRED_IFACE (connection: ${WIRED_CONN:-none})"
}

pick_hostel() {
  local -a names groups froms tos gws prefixes proxses pdfs
  local line i=0
  while IFS='|' read -r name group ip_from ip_to gw prefix proxies pdf rest; do
    [[ "$name" =~ ^# ]] && continue
    [[ -z "$name" ]] && continue
    names[i]="$name"; groups[i]="$group"
    froms[i]="$ip_from"; tos[i]="$ip_to"
    gws[i]="$gw"; prefixes[i]="$prefix"
    proxses[i]="$proxies"; pdfs[i]="$pdf"
    i=$((i+1))
  done < "$TSV"
  local count=$i
  log "Select your hostel/hall:"
  echo ""
  local prev_group="" idx
  for ((i=0; i<count; i++)); do
    if [[ "${groups[i]}" != "$prev_group" ]]; then
      echo -e "${B}--- ${groups[i]} ---${N}"
      prev_group="${groups[i]}"
    fi
    printf "  %2d) %s\n" $((i+1)) "${names[i]}"
  done
  echo ""
  local choice
  while :; do
    choice=$(ask "Enter number" "")
    [[ -z "$choice" ]] && continue
    local re='^[0-9]+$'
    if [[ "$choice" =~ $re ]] && ((choice >= 1 && choice <= count)); then
      break
    fi
    warn "Enter a number between 1 and $count"
  done
  idx=$((choice-1))
  SELECTED_HOSTEL_NAME="${names[idx]}"
  SELECTED_HOSTEL_GW="${gws[idx]}"
  SELECTED_HOSTEL_PREFIX="${prefixes[idx]}"
  SELECTED_HOSTEL_PROXIES="${proxses[idx]}"
  local ip_from="${froms[idx]}" ip_to="${tos[idx]}" pdf="${pdfs[idx]}"

  echo ""
  echo -e "${B}${C}📄  Find your room's IP here:${N}"
  echo -e "${C}   $pdf${N}"
  echo -e "${Y}   Press Enter after you've found your IP.${N}"
  ask "Press Enter to continue" ""

  while :; do
    local ip
    ip=$(ask "Enter the assigned IP" "")
    if [[ -z "$ip" ]]; then
      warn "IP cannot be empty"
      continue
    fi
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      warn "Not a valid IP address"
      continue
    fi
    if in_range "$ip" "$ip_from" "$ip_to"; then
      SELECTED_HOSTEL_IP="$ip"; break
    else
      echo -e "${Y}⚠  $ip is outside ${SELECTED_HOSTEL_NAME}'s documented range (${ip_from}–${ip_to}).${N}"
      if confirm "Still use this IP?" "y"; then
        SELECTED_HOSTEL_IP="$ip"; break
      else
        echo "Let's try again."
      fi
    fi
  done

  if [[ "$SELECTED_HOSTEL_GW" == "floorwise" ]]; then
    local IFS=. a b c d
    read -r a b c d <<< "$SELECTED_HOSTEL_IP"
    SELECTED_HOSTEL_GW="${a}.${b}.${c}.1"
    SELECTED_HOSTEL_PREFIX="24"
    echo -e "${Y}  ⓘ  Floor-wise subnet  -  gateway set to ${SELECTED_HOSTEL_GW}${N}"
    if ! confirm "Is this correct?" "y"; then
      SELECTED_HOSTEL_GW=$(ask "Enter gateway IP" "")
    fi
  fi

  ok "Hostel: $SELECTED_HOSTEL_NAME"
  ok "IP: $SELECTED_HOSTEL_IP / $SELECTED_HOSTEL_PREFIX  GW: $SELECTED_HOSTEL_GW"
  ok "Proxies: $SELECTED_HOSTEL_PROXIES"
}

apply_ip() {
  if [[ -z "$WIRED_CONN" ]]; then
    warn "No NetworkManager connection found  -  skipping static IP."
    return
  fi
  log "Applying static IP..."
  nmcli con mod "$WIRED_CONN" \
    ipv4.method manual \
    ipv4.addresses "${SELECTED_HOSTEL_IP}/${SELECTED_HOSTEL_PREFIX}" \
    ipv4.gateway "$SELECTED_HOSTEL_GW" \
    ipv4.dns "$DNS_SRV_LIST"
  local carrier
  carrier=$(cat /sys/class/net/"$WIRED_IFACE"/carrier 2>/dev/null || echo 0)
  if [[ "$carrier" == "1" ]]; then
    nmcli con down "$WIRED_CONN" 2>/dev/null || true
    nmcli con up "$WIRED_CONN" 2>/dev/null || warn "Connection activation failed"
    ok "Static IP applied"
  else
    warn "Cable not plugged in  -  IP config saved, will activate at hostel."
  fi
}

gen_config() {
  log "Regenerating config..."
  local proxy_entries="" proxy_names=""
  local IFS=',' p name
  local idx=0
  for p in $SELECTED_HOSTEL_PROXIES; do
    idx=$((idx+1))
    name="proxy-${idx}"
    proxy_entries+="  - {name: ${name}, type: http, server: ${p}, port: ${PROXY_PORT}, username: ${PROXY_USER}, password: ${PROXY_PASS}}"$'\n'
    [[ -n "$proxy_names" ]] && proxy_names+=", "
    proxy_names+="${name}"
  done
  mkdir -p /etc/mihomo
  local rendered
  rendered=$(python3 -c '
import sys
proxy_entries = sys.argv[1]
proxy_names   = sys.argv[2]
template_path = sys.argv[3]
with open(template_path) as f:
    t = f.read()
t = t.replace("{{PROXY_ENTRIES}}", proxy_entries.rstrip("\n"))
t = t.replace("{{PROXY_NAMES}}", proxy_names)
sys.stdout.write(t)
' "$proxy_entries" "$proxy_names" "$TEMPLATE") || die "Failed to render config"
  printf '%s\n' "$rendered" > /etc/mihomo/config.yaml
  chmod 600 /etc/mihomo/config.yaml
  mihomo -t -d /etc/mihomo 2>&1 || die "Config validation failed"
  ok "Config updated"
  if systemctl is-active --quiet mihomo; then
    systemctl restart mihomo
    ok "mihomo restarted"
  fi
}

show_status() {
  log "Current status:"
  if systemctl is-active --quiet mihomo 2>/dev/null; then ok "mihomo  -  running"
  else warn "mihomo  -  not running"; fi
  echo ""
  detect_iface || true
  if [[ -n "$WIRED_IFACE" ]]; then
    local ip gw
    ip=$(ip -4 addr show "$WIRED_IFACE" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
    gw=$(ip route show default dev "$WIRED_IFACE" 2>/dev/null | awk '{print $3}')
    echo "   IP: ${ip:-none}"
    echo "   Gateway: ${gw:-none}"
  fi
  echo ""
  if [[ -f /etc/mihomo/config.yaml ]]; then
    echo -e "${B}Proxies in config:${N}"
    grep -oP 'server: \K[0-9.]+' /etc/mihomo/config.yaml | sed 's/^/   /'
  fi
  echo ""
  echo -e "${Y}${B}Note: ping & voice calls don't work through the proxy  -  expected.${N}"
  echo ""
  ask "Press Enter to continue" ""
}

restore_dhcp() {
  log "Restoring DHCP and stopping proxy..."
  detect_iface || true
  if [[ -n "$WIRED_CONN" ]]; then
    nmcli con mod "$WIRED_CONN" ipv4.method auto ipv4.addresses "" ipv4.gateway "" 2>/dev/null || true
    nmcli con up "$WIRED_CONN" 2>/dev/null || true
    ok "DHCP restored"
  else
    warn "No connection profile found  -  set DHCP manually if needed."
  fi
  systemctl stop mihomo 2>/dev/null || true
  ok "mihomo stopped"
  echo -e "${Y}Note: mihomo will restart automatically when you plug back into campus LAN (if LAN watcher is installed).${N}"
}

toggle_watcher() {
  local file=/etc/NetworkManager/dispatcher.d/90-mihomo-lan
  if [[ -f "$file" ]]; then
    if confirm "LAN watcher is INSTALLED. Remove it?" "n"; then
      rm -f "$file"
      nmcli general reload 2>/dev/null || true
      systemctl enable mihomo 2>/dev/null || true
      ok "LAN watcher removed  -  mihomo now auto-starts at boot instead."
    fi
  else
    if confirm "LAN watcher is NOT installed. Install it (auto start/stop with LAN)?" "y"; then
      if [[ -f /opt/mnnit-proxy/90-mihomo-lan ]]; then
        mkdir -p /etc/NetworkManager/dispatcher.d
        cp /opt/mnnit-proxy/90-mihomo-lan "$file"
        chmod 755 "$file"
        nmcli general reload 2>/dev/null || true
        systemctl disable mihomo 2>/dev/null || true
        ok "LAN watcher installed."
      else
        warn "Dispatcher file not found  -  re-run install.sh."
      fi
    fi
  fi
}

menu() {
  echo -e "${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${B}${C}  mnnit-proxy updater v${VERSION}${N}"
  echo -e "${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""
  echo "  [1] Change hostel / IP"
  echo "  [2] Restore DHCP & stop proxy (going home)"
  echo "  [3] Show current status"
  echo "  [4] Toggle LAN auto-watch"
  echo "  [5] Exit"
  echo ""
  local choice
  choice=$(ask "Enter number" "1")
  case "$choice" in
    1)
      pick_hostel
      apply_ip
      gen_config
      echo ""
      ok "Done. Your proxy is now configured for $SELECTED_HOSTEL_NAME."
      ;;
    2) restore_dhcp ;;
    3) show_status ;;
    4) toggle_watcher ;;
    5) exit 0 ;;
    *) warn "Invalid choice"; menu ;;
  esac
}

if (( EUID != 0 )); then
  echo -e "${Y}This script needs root privileges. Run: ${B}sudo bash update.sh${N}"
  exit 0
fi

menu