#!/usr/bin/env bash
# mnnit-proxy updater  -  change hostel/IP, restore DHCP, status, toggle LAN watcher.
# Does NOT reinstall mihomo. Requires an existing install (or /opt toolkit).
#
# Usage:
#   sudo bash update.sh                                    # interactive menu
#   sudo bash update.sh --action change-ip --hostel N --ip IP --yes
#   sudo bash update.sh --action dhcp                      # restore DHCP + stop
#   sudo bash update.sh --action status
#   sudo bash update.sh --action watch                     # toggle LAN watcher
set -Eeuo pipefail

readonly APP_VERSION="1.1.0"
readonly PROXY_PORT=3128
readonly PROXY_USER="edcguest"
readonly PROXY_PASS="edcguest"
readonly DNS_SRV="172.31.100.6, 172.31.100.7, 172.31.100.8"
readonly DNS_SRV_LIST="172.31.100.6,172.31.100.7,172.31.100.8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || pwd)"
if [[ -f "$SCRIPT_DIR/hostels.tsv" && -f "$SCRIPT_DIR/config.template.yaml" ]]; then
  TSV="$SCRIPT_DIR/hostels.tsv"
  TEMPLATE="$SCRIPT_DIR/config.template.yaml"
elif [[ -f /opt/mnnit-proxy/hostels.tsv && -f /opt/mnnit-proxy/config.template.yaml ]]; then
  TSV="/opt/mnnit-proxy/hostels.tsv"
  TEMPLATE="/opt/mnnit-proxy/config.template.yaml"
else
  echo "mnnit-proxy is not installed (no data files found)." >&2
  echo "Run install.sh first." >&2
  exit 1
fi

WIRED_IFACE=""
WIRED_CONN=""
SELECTED_HOSTEL_NAME=""
SELECTED_HOSTEL_IP=""
SELECTED_HOSTEL_GW=""
SELECTED_HOSTEL_PREFIX=""
SELECTED_HOSTEL_PROXIES=""

FLAG_HOSTEL=""
FLAG_IP=""
FLAG_GATEWAY=""
FLAG_FORCE=false
FLAG_YES=false
ACTION=""

if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; C=""; B=""; N=""
fi
log()  { echo -e "${B}${C}[*]${N} $*"; }
ok()   { echo -e " ${G}${B}✓${N} $*"; }
warn() { echo -e " ${Y}${B}⚠${N} $*"; }
fail() { echo -e " ${R}${B}✗${N} $*"; }
die()  { fail "$*"; exit 1; }

__tty_read() {
  if [[ -t 0 ]]; then read -r "$@"; return 0; fi
  if [[ -r /dev/tty ]]; then read -r "$@" < /dev/tty; return 0; fi
  return 1
}
ask() {
  local prompt="$1" default="${2:-}" reply=""
  echo -en "${B}${prompt}${N} " >&2
  __tty_read reply || reply=""
  if [[ -z "$reply" && -n "$default" ]]; then reply="$default"; fi
  echo "$reply"
}
confirm() {
  local prompt="$1" default="${2:-y}" reply=""
  local dfl="${default^^}"
  echo -en "${B}${prompt}${N} [${dfl}] " >&2
  __tty_read reply || reply=""
  if [[ -z "$reply" ]]; then reply="$default"; fi
  [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

ip2int() {
  local IFS=. a b c d
  read -r a b c d <<< "$1"
  echo "$((a<<24 | b<<16 | c<<8 | d))"
}
in_range() {
  local ip_i from_i to_i
  ip_i=$(ip2int "$1"); from_i=$(ip2int "$2"); to_i=$(ip2int "$3")
  ((ip_i >= from_i && ip_i <= to_i))
}
valid_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

detect_iface() {
  local -a ifaces=()
  local d i
  for d in /sys/class/net/*; do
    i="${d##*/}"
    [[ "$i" =~ ^(en|eth) ]] && ifaces+=("$i")
  done
  if [[ ${#ifaces[@]} -eq 0 ]]; then
    warn "No ethernet interface found."
    return 1
  fi
  local iface="" i2
  for i2 in "${ifaces[@]}"; do
    if [[ "$(cat "/sys/class/net/$i2/carrier" 2>/dev/null)" == "1" ]]; then
      iface="$i2"; break
    fi
  done
  iface="${iface:-${ifaces[0]}}"
  WIRED_IFACE="$iface"
  if command -v nmcli &>/dev/null; then
    WIRED_CONN=$(nmcli -g GENERAL.CONNECTION device show "$WIRED_IFACE" 2>/dev/null | head -1 || true)
    if [[ -z "$WIRED_CONN" ]]; then
      WIRED_CONN=$(nmcli -t -f NAME,TYPE con show 2>/dev/null | grep ':802-3-ethernet' | cut -d: -f1 | head -1 || true)
    fi
  fi
  ok "Interface: $WIRED_IFACE (connection: ${WIRED_CONN:-none})"
  return 0
}

load_hostels() {
  HOSTEL_NAMES=(); HOSTEL_GROUPS=(); HOSTEL_FROMS=(); HOSTEL_TOS=()
  HOSTEL_GWS=(); HOSTEL_PREFIXES=(); HOSTEL_PROXIES=(); HOSTEL_PDFS=()
  local name group ip_from ip_to gw prefix proxies pdf
  while IFS='|' read -r name group ip_from ip_to gw prefix proxies pdf _; do
    [[ "$name" =~ ^# || -z "$name" ]] && continue
    HOSTEL_NAMES+=("$name");  HOSTEL_GROUPS+=("$group")
    HOSTEL_FROMS+=("$ip_from"); HOSTEL_TOS+=("$ip_to")
    HOSTEL_GWS+=("$gw");      HOSTEL_PREFIXES+=("$prefix")
    HOSTEL_PROXIES+=("$proxies"); HOSTEL_PDFS+=("$pdf")
  done < "$TSV"
}

resolve_hostel_by_name() {
  local query="$1" idx i
  load_hostels
  local matches=()
  for i in "${!HOSTEL_NAMES[@]}"; do
    local lname="${HOSTEL_NAMES[i],,}"
    local lquery="${query,,}"
    if [[ "$lname" == "$lquery" || "$lname" == *"$lquery"* ]]; then
      matches+=("$i")
    fi
  done
  if [[ ${#matches[@]} -eq 0 ]]; then
    fail "No hostel matches '$query'."
    return 1
  fi
  if [[ ${#matches[@]} -gt 1 ]]; then
    fail "'$query' matches multiple hostels  -  be more specific:"
    for idx in "${matches[@]}"; do echo "  - ${HOSTEL_NAMES[idx]}" >&2; done
    return 1
  fi
  idx="${matches[0]}"
  SELECTED_HOSTEL_NAME="${HOSTEL_NAMES[idx]}"
  SELECTED_HOSTEL_GW="${HOSTEL_GWS[idx]}"
  SELECTED_HOSTEL_PREFIX="${HOSTEL_PREFIXES[idx]}"
  SELECTED_HOSTEL_PROXIES="${HOSTEL_PROXIES[idx]}"
  if ! in_range "$SELECTED_HOSTEL_IP" "${HOSTEL_FROMS[idx]}" "${HOSTEL_TOS[idx]}"; then
    if [[ "$FLAG_FORCE" != true ]]; then
      die "$SELECTED_HOSTEL_IP is outside ${SELECTED_HOSTEL_NAME}'s documented range (${HOSTEL_FROMS[idx]}–${HOSTEL_TOS[idx]}). Use --force to override."
    fi
    warn "IP outside documented range  -  proceeding (--force)"
  fi
  return 0
}

derive_network() {
  if [[ "$SELECTED_HOSTEL_PREFIX" == "floorwise" ]]; then
    local IFS=. a b c d
    read -r a b c d <<< "$SELECTED_HOSTEL_IP"
    if [[ "$SELECTED_HOSTEL_GW" == "floorwise" ]]; then
      SELECTED_HOSTEL_GW="${a}.${b}.${c}.1"
    fi
    SELECTED_HOSTEL_PREFIX="24"
  fi
  if [[ -n "$FLAG_GATEWAY" ]]; then
    SELECTED_HOSTEL_GW="$FLAG_GATEWAY"
  fi
}

show_summary() {
  echo ""
  echo -e "${B}┌─ Configuration summary ──────────────────────────────${N}"
  echo -e "${B}│${N} Hostel:  ${SELECTED_HOSTEL_NAME}"
  echo -e "${B}│${N} IP:      ${SELECTED_HOSTEL_IP}/${SELECTED_HOSTEL_PREFIX}"
  echo -e "${B}│${N} Gateway: ${SELECTED_HOSTEL_GW}"
  echo -e "${B}│${N} DNS:     ${DNS_SRV}"
  echo -e "${B}│${N} Proxies: ${SELECTED_HOSTEL_PROXIES} (port ${PROXY_PORT})"
  echo -e "${B}└──────────────────────────────────────────────────────${N}"
}

summary_edit_loop() {
  while :; do
    show_summary
    if confirm "Everything correct?" "y"; then
      return 0
    fi
    echo ""
    echo "  [1] Re-enter IP"
    echo "  [2] Change gateway"
    echo "  [3] Change subnet prefix (CIDR)"
    echo "  [4] Change proxy list"
    echo "  [5] Start over  -  pick a different hostel"
    echo "  [6] Cancel"
    echo ""
    local choice
    choice=$(ask "Enter number" "")
    case "$choice" in
      1)
        while :; do
          local ip
          ip=$(ask "Enter the assigned IP" "$SELECTED_HOSTEL_IP")
          if valid_ip "$ip"; then SELECTED_HOSTEL_IP="$ip"; break; fi
          warn "Not a valid IP address"
        done
        ;;
      2)
        while :; do
          local gw
          gw=$(ask "Enter gateway IP" "$SELECTED_HOSTEL_GW")
          if valid_ip "$gw"; then SELECTED_HOSTEL_GW="$gw"; break; fi
          warn "Not a valid IP address"
        done
        ;;
      3)
        while :; do
          local pfx
          pfx=$(ask "Enter prefix length (8-32)" "$SELECTED_HOSTEL_PREFIX")
          if [[ "$pfx" =~ ^([8-9]|[12][0-9]|3[0-2])$ ]]; then SELECTED_HOSTEL_PREFIX="$pfx"; break; fi
          warn "Prefix must be 8-32"
        done
        ;;
      4)
        while :; do
          local pl
          pl=$(ask "Proxies (comma-separated IPs)" "$SELECTED_HOSTEL_PROXIES")
          local IFS=, ok_all=true p
          read -ra plist <<< "$pl"
          unset IFS
          for p in "${plist[@]}"; do
            valid_ip "$p" || ok_all=false
          done
          if [[ "$ok_all" == true && ${#plist[@]} -gt 0 ]]; then
            SELECTED_HOSTEL_PROXIES="$pl"; break
          fi
          warn "All entries must be valid comma-separated IPs"
        done
        ;;
      5) pick_hostel; return 0 ;;
      6) die "Cancelled." ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

pick_hostel() {
  load_hostels
  local count=${#HOSTEL_NAMES[@]}
  log "Select your hostel/hall:"
  echo ""
  local prev_group="" i
  for i in "${!HOSTEL_NAMES[@]}"; do
    if [[ "${HOSTEL_GROUPS[i]}" != "$prev_group" ]]; then
      echo -e "${B}--- ${HOSTEL_GROUPS[i]} ---${N}"
      prev_group="${HOSTEL_GROUPS[i]}"
    fi
    printf "  %2d) %s\n" $((i+1)) "${HOSTEL_NAMES[i]}"
  done
  echo ""
  local choice
  while :; do
    choice=$(ask "Enter number" "")
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
      break
    fi
    warn "Enter a number between 1 and $count"
  done
  local idx=$((choice-1))
  SELECTED_HOSTEL_NAME="${HOSTEL_NAMES[idx]}"
  SELECTED_HOSTEL_GW="${HOSTEL_GWS[idx]}"
  SELECTED_HOSTEL_PREFIX="${HOSTEL_PREFIXES[idx]}"
  SELECTED_HOSTEL_PROXIES="${HOSTEL_PROXIES[idx]}"
  local ip_from="${HOSTEL_FROMS[idx]}" ip_to="${HOSTEL_TOS[idx]}" pdf="${HOSTEL_PDFS[idx]}"

  echo ""
  echo -e "${B}${C}📄  Find your room's IP here (open on phone/PC):${N}"
  echo -e "${C}   $pdf${N}"
  ask "Press Enter when you have it" ""

  while :; do
    local ip
    ip=$(ask "Enter the assigned IP from the PDF" "")
    if [[ -z "$ip" ]]; then warn "IP cannot be empty"; continue; fi
    if ! valid_ip "$ip"; then warn "Not a valid IP address"; continue; fi
    if in_range "$ip" "$ip_from" "$ip_to"; then
      SELECTED_HOSTEL_IP="$ip"; break
    fi
    echo -e "${Y}⚠  $ip is outside ${SELECTED_HOSTEL_NAME}'s documented range (${ip_from}–${ip_to}).${N}"
    if confirm "The college PDF may be outdated. Still use this IP?" "y"; then
      SELECTED_HOSTEL_IP="$ip"; break
    fi
    echo "Let's try again."
  done

  derive_network

  if [[ "${HOSTEL_PREFIXES[idx]}" == "floorwise" ]]; then
    echo -e "${Y}  ⓘ  ${SELECTED_HOSTEL_NAME} uses floor-wise subnets  -  gateway below is derived, verify it!${N}"
    if ! confirm "Use derived gateway ${SELECTED_HOSTEL_GW}?" "n"; then
      while :; do
        local gw
        gw=$(ask "Enter the gateway from your floor's PDF" "")
        if valid_ip "$gw"; then SELECTED_HOSTEL_GW="$gw"; break; fi
        warn "Not a valid IP address"
      done
    fi
  fi

  summary_edit_loop
  ok "Selected: $SELECTED_HOSTEL_NAME  -  $SELECTED_HOSTEL_IP/$SELECTED_HOSTEL_PREFIX via $SELECTED_HOSTEL_GW"
}

apply_ip() {
  if [[ -z "$WIRED_CONN" ]]; then
    warn "No NetworkManager connection profile  -  set the IP manually."
    return 0
  fi
  log "Applying static IP on '$WIRED_CONN'..."
  nmcli con mod "$WIRED_CONN" \
    ipv4.method manual \
    ipv4.addresses "${SELECTED_HOSTEL_IP}/${SELECTED_HOSTEL_PREFIX}" \
    ipv4.gateway "$SELECTED_HOSTEL_GW" \
    ipv4.dns "$DNS_SRV_LIST"
  local carrier
  carrier=$(cat "/sys/class/net/$WIRED_IFACE/carrier" 2>/dev/null || echo 0)
  if [[ "$carrier" == "1" ]]; then
    nmcli con down "$WIRED_CONN" 2>/dev/null || true
    nmcli con up "$WIRED_CONN" || warn "Connection activation failed"
    ok "Static IP applied"
  else
    nmcli con up "$WIRED_CONN" 2>/dev/null || true
    warn "Cable not plugged in  -  config saved; activates at hostel."
  fi
}

gen_config() {
  log "Regenerating config..."
  local proxy_entries="" proxy_names=""
  local idx=0 p name
  local IFS=,
  read -ra plist <<< "$SELECTED_HOSTEL_PROXIES"
  unset IFS
  for p in "${plist[@]}"; do
    p="${p//[[:space:]]/}"
    idx=$((idx+1))
    name="proxy-${idx}"
    proxy_entries+="  - {name: ${name}, type: http, server: ${p}, port: ${PROXY_PORT}, username: ${PROXY_USER}, password: ${PROXY_PASS}}"$'\n'
    [[ -n "$proxy_names" ]] && proxy_names+=", "
    proxy_names+="${name}"
  done
  # Preserve current tun state when the config already exists
  local tun_enable="true"
  if [[ -f /etc/mihomo/config.yaml ]] && grep -qE '^tun:' /etc/mihomo/config.yaml; then
    local cur
    cur=$(awk '/^tun:/{f=1;next} f && /^  enable:/{print $2; exit}' /etc/mihomo/config.yaml)
    if [[ "$cur" == "false" ]]; then tun_enable="false"; fi
  fi

  mkdir -p /etc/mihomo
  local rendered
  rendered=$(python3 - "$proxy_entries" "$proxy_names" "$tun_enable" "$TEMPLATE" <<'PYEOF'
import sys
proxy_entries, proxy_names, tun_enable, template_path = sys.argv[1:5]
with open(template_path) as f:
    t = f.read()
t = t.replace("{{PROXY_ENTRIES}}", proxy_entries.rstrip("\n"))
t = t.replace("{{PROXY_NAMES}}", proxy_names)
t = t.replace("{{TUN_ENABLE}}", tun_enable)
sys.stdout.write(t)
PYEOF
  ) || die "Failed to render config"
  printf '%s\n' "$rendered" > /etc/mihomo/config.yaml
  chmod 600 /etc/mihomo/config.yaml
  mihomo -t -d /etc/mihomo >/dev/null 2>&1 || {
    mihomo -t -d /etc/mihomo 2>&1 || true
    die "Config validation failed"
  }
  ok "Config updated (tun: $tun_enable)"
  if systemctl is-active --quiet mihomo 2>/dev/null; then
    systemctl restart mihomo
    ok "mihomo restarted"
  fi
}

show_status() {
  log "Current status:"
  if systemctl is-active --quiet mihomo 2>/dev/null; then
    ok "mihomo  -  running"
  else
    warn "mihomo  -  not running"
  fi
  echo ""
  if detect_iface; then
    local ip gw
    ip=$(ip -4 addr show "$WIRED_IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
    gw=$(ip route show default dev "$WIRED_IFACE" 2>/dev/null | awk '{print $3; exit}')
    echo "   IP: ${ip:-none}"
    echo "   Gateway: ${gw:-none}"
    if [[ "$gw" == 172.31.* ]]; then
      ok "On campus network"
    else
      warn "Not on campus (or cable unplugged)"
    fi
  fi
  echo ""
  if [[ -f /etc/mihomo/config.yaml ]]; then
    echo -e "${B}Proxies in config:${N}"
    grep -oP 'server: \K[0-9.]+' /etc/mihomo/config.yaml | sed 's/^/   /'
  fi
  echo ""
  echo -e "${Y}Note: ping & voice calls don't work through the proxy  -  expected.${N}"
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
  echo -e "${Y}Note: mihomo restarts automatically when you plug back into campus LAN (if LAN watcher is installed).${N}"
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
      local src=""
      if [[ -f "$SCRIPT_DIR/dispatcher/90-mihomo-lan" ]]; then
        src="$SCRIPT_DIR/dispatcher/90-mihomo-lan"
      elif [[ -f /opt/mnnit-proxy/90-mihomo-lan ]]; then
        src="/opt/mnnit-proxy/90-mihomo-lan"
      fi
      if [[ -n "$src" ]]; then
        mkdir -p /etc/NetworkManager/dispatcher.d
        install -m 755 -o root -g root "$src" "$file"
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
  echo -e "${B}${C}  mnnit-proxy updater v${APP_VERSION}${N}"
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
      ok "Done. Configured for $SELECTED_HOSTEL_NAME."
      ;;
    2) restore_dhcp ;;
    3) show_status ;;
    4) toggle_watcher ;;
    5) exit 0 ;;
    *) warn "Invalid choice"; menu ;;
  esac
}

parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --action)     [[ $# -lt 2 ]] && die "--action needs a value"; ACTION="$2"; shift 2 ;;
      --hostel)     [[ $# -lt 2 ]] && die "--hostel needs a value"; FLAG_HOSTEL="$2"; shift 2 ;;
      --ip)         [[ $# -lt 2 ]] && die "--ip needs a value"; FLAG_IP="$2"; shift 2 ;;
      --gateway)    [[ $# -lt 2 ]] && die "--gateway needs a value"; FLAG_GATEWAY="$2"; shift 2 ;;
      --yes|-y)     FLAG_YES=true; shift ;;
      --force)      FLAG_FORCE=true; shift ;;
      --non-interactive) FLAG_YES=true; shift ;;
      -h|--help)    sed -n "2,10p" "${BASH_SOURCE[0]:-$0}"; exit 0 ;;
      *)            die "Unknown flag: $1" ;;
    esac
  done
}

main() {
  parse_flags "$@"
  if [[ $EUID -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]}" && "${BASH_SOURCE[0]}" != "-" && -f "${BASH_SOURCE[0]}" && -r /dev/tty ]]; then
      warn "This script needs root. Re-running with sudo..."
      exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    fi
    die "This script needs root. Run with sudo."
  fi
  case "$ACTION" in
    change-ip)
      if [[ -z "$FLAG_HOSTEL" || -z "$FLAG_IP" ]]; then
        die "--action change-ip needs --hostel and --ip"
      fi
      SELECTED_HOSTEL_IP="$FLAG_IP"
      if ! resolve_hostel_by_name "$FLAG_HOSTEL"; then exit 1; fi
      derive_network
      apply_ip
      gen_config
      ok "Done. Configured for $SELECTED_HOSTEL_NAME."
      ;;
    dhcp)  restore_dhcp ;;
    status) show_status ;;
    watch) toggle_watcher ;;
    "")
      if [[ "$FLAG_YES" == true && -n "$FLAG_HOSTEL" && -n "$FLAG_IP" ]]; then
        SELECTED_HOSTEL_IP="$FLAG_IP"
        if ! resolve_hostel_by_name "$FLAG_HOSTEL"; then exit 1; fi
        derive_network
        apply_ip
        gen_config
        ok "Done. Configured for $SELECTED_HOSTEL_NAME."
      else
        menu
      fi
      ;;
    *) die "Unknown action: $ACTION (use change-ip|dhcp|status|watch)" ;;
  esac
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi