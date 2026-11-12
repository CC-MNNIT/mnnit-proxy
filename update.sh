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
#
# Flags:
#   --hostel NAME      hostel name (exact or unique substring)
#   --ip IP            your room IP from the hostel PDF
#   --gateway IP       override the derived gateway
#   --force            proceed even if IP is outside the documented range
#   --yes|-y           accept prompts (unattended)
#   --interface IFACE  campus Ethernet interface
#   --tun-stack STACK  system|gvisor|mixed|mips (preserves current if omitted)
set -Eeuo pipefail

readonly APP_VERSION="1.3.0"
readonly PROXY_PORT=3128
readonly PROXY_USER="edcguest"
readonly PROXY_PASS="edcguest"
readonly DNS_SRV="172.31.100.6, 172.31.100.7, 172.31.100.8"
readonly DNS_SRV_LIST="172.31.100.6,172.31.100.7,172.31.100.8"
readonly DEFAULT_TUN_STACK="gvisor"
readonly CAMPUS_ROUTE="172.31.0.0/16"
readonly STATE_FILE="${MNNIT_STATE_FILE:-/opt/mnnit-proxy/state}"

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
NET_BACKEND=""   # networkmanager | netplan | manual
SELECTED_HOSTEL_NAME=""
SELECTED_HOSTEL_IP=""
SELECTED_HOSTEL_GW=""
SELECTED_HOSTEL_PREFIX=""
SELECTED_HOSTEL_PROXIES=""
SELECTED_HOSTEL_FLOORWISE=false

FLAG_HOSTEL=""
FLAG_IP=""
FLAG_GATEWAY=""
FLAG_FORCE=false
FLAG_YES=false
FLAG_INTERFACE=""
FLAG_TUN_STACK=""
ACTION=""
PROFILE_CREATED=false
PREVIOUS_CONN=""
STATE_WIRED_IFACE=""
STATE_WIRED_CONN=""
STATE_PROFILE_CREATED=false
STATE_PREVIOUS_CONN=""
CONFIG_HAD_PREVIOUS=false
readonly CONFIG_BACKUP="/etc/mihomo/config.yaml.previous"

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
  echo "$((10#$a<<24 | 10#$b<<16 | 10#$c<<8 | 10#$d))"
}
in_range() {
  local ip_i from_i to_i
  ip_i=$(ip2int "$1"); from_i=$(ip2int "$2"); to_i=$(ip2int "$3")
  ((ip_i >= from_i && ip_i <= to_i))
}
# Strict: four dot-separated octets, each 0-255 (leading zeros parsed base-10).
valid_ip() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o
  for o in "${BASH_REMATCH[@]:1}"; do
    (( 10#$o <= 255 )) || return 1
  done
  return 0
}

# ---- backend classification (same rules as install.sh) ----
detect_backend() {
  NET_BACKEND="${MNNIT_FORCE_BACKEND:-}"
  [[ -n "$NET_BACKEND" ]] && return 0   # test seam
  if command -v nmcli &>/dev/null && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    NET_BACKEND="networkmanager"
  elif command -v netplan &>/dev/null && [[ -d "${NETPLAN_DIR:-/etc/netplan}" ]]; then
    NET_BACKEND="netplan"
  else
    NET_BACKEND="manual"
  fi
}

NETPLAN_FILE="/etc/netplan/99-mnnit-proxy.yaml"

netplan_yaml() {
  cat <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $WIRED_IFACE:
      dhcp4: no
      addresses: [$SELECTED_HOSTEL_IP/$SELECTED_HOSTEL_PREFIX]
      routes:
        - to: default
          via: $SELECTED_HOSTEL_GW
        - to: $CAMPUS_ROUTE
          via: $SELECTED_HOSTEL_GW
      nameservers:
        addresses: [${DNS_SRV_LIST//,/ }]
EOF
}

# Scan the directory of NETPLAN_FILE (same base dir in prod and tests).
netplan_iface_conflicts() {
  local base_dir
  base_dir="$(dirname "$NETPLAN_FILE")"
  local file
  for file in "$base_dir"/*.yaml; do
    [[ -f "$file" ]] || continue
    [[ "$file" == "$NETPLAN_FILE" ]] && continue
    if grep -Fq "$WIRED_IFACE:" "$file" 2>/dev/null; then
      echo "$file"
      return 0
    fi
  done
  return 1
}

print_manual_ip_instructions() {
  cat <<EOF

  No NetworkManager or netplan found  -  set your static IP manually.
  Paste this whole block into a terminal (values are filled in for you):

  ┌────────────── COPY FROM HERE ──────────────
  │ sudo tee /etc/netplan/99-mnnit-proxy.yaml >/dev/null <<'NETPLAN'
  │ network:
  │   version: 2
  │   renderer: networkd
  │   ethernets:
  │     $WIRED_IFACE:
  │       dhcp4: no
  │       addresses: [$SELECTED_HOSTEL_IP/$SELECTED_HOSTEL_PREFIX]
  │       routes:
  │         - to: default
  │           via: $SELECTED_HOSTEL_GW
  │         - to: $CAMPUS_ROUTE
  │           via: $SELECTED_HOSTEL_GW
  │       nameservers:
  │         addresses: [${DNS_SRV_LIST//,/ }]
  │ NETPLAN
  │ sudo chmod 600 /etc/netplan/99-mnnit-proxy.yaml
  │ sudo netplan apply
  └────────────── COPY TO HERE ───────────────

  Then verify with:  ip -4 addr show $WIRED_IFACE
EOF
}

apply_netplan() {
  log "Applying static IP via netplan..."
  local conflict
  conflict=$(netplan_iface_conflicts || true)
  if [[ -n "$conflict" ]]; then
    warn "Existing netplan file already configures $WIRED_IFACE: $(basename "$conflict")"
    warn "Not touching it  -  add these values there manually:"
    netplan_yaml | sed 's/^/    /'
    return 1
  fi
  local backup=""
  if [[ -f "$NETPLAN_FILE" ]]; then
    backup="${NETPLAN_FILE}.previous"
    cp -a "$NETPLAN_FILE" "$backup"
  fi
  netplan_yaml > "$NETPLAN_FILE.tmp"
  mv "$NETPLAN_FILE.tmp" "$NETPLAN_FILE"
  chmod 600 "$NETPLAN_FILE"
  if netplan apply 2>/dev/null; then
    sleep 2
    if ip -4 addr show "$WIRED_IFACE" 2>/dev/null | grep -q "$SELECTED_HOSTEL_IP/"; then
      ok "Static IP applied via netplan ($NETPLAN_FILE)"
      return 0
    fi
    warn "netplan apply ran but the IP is not on $WIRED_IFACE yet"
    if [[ -n "$backup" ]]; then cp -a "$backup" "$NETPLAN_FILE"; else rm -f "$NETPLAN_FILE"; fi
    return 1
  fi
  if [[ -n "$backup" ]]; then cp -a "$backup" "$NETPLAN_FILE"; else rm -f "$NETPLAN_FILE"; fi
  warn "netplan apply failed  -  our config was rolled back. Instructions:"
  print_manual_ip_instructions
  return 1
}

# ---- preflight (updater needs less, but fail clearly) ----
preflight() {
  local missing=() cmd
  for cmd in python3 ip mihomo; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}  -  is mnnit-proxy fully installed?"
  fi
  detect_backend
}

valid_tun_stack() {
  case "$1" in
    system|gvisor|mixed|mips) return 0 ;;
    *) return 1 ;;
  esac
}

load_state() {
  STATE_WIRED_IFACE=""
  STATE_WIRED_CONN=""
  STATE_PROFILE_CREATED=false
  STATE_PREVIOUS_CONN=""
  [[ -f "$STATE_FILE" ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      WIRED_IFACE)      [[ "$value" =~ ^[[:alnum:]_.:-]+$ ]] && STATE_WIRED_IFACE="$value" ;;
      WIRED_CONN)       [[ "$value" =~ ^[[:xdigit:]-]+$ ]] && STATE_WIRED_CONN="$value" ;;
      PROFILE_CREATED)  [[ "$value" == true || "$value" == false ]] && STATE_PROFILE_CREATED="$value" ;;
      PREVIOUS_CONN)    [[ -z "$value" || "$value" =~ ^[[:xdigit:]-]+$ ]] && STATE_PREVIOUS_CONN="$value" ;;
    esac
  done < "$STATE_FILE"
}

save_state() {
  mkdir -p "$(dirname "$STATE_FILE")"
  local tmp="${STATE_FILE}.tmp"
  {
    printf 'WIRED_IFACE=%s\n' "$WIRED_IFACE"
    printf 'WIRED_CONN=%s\n' "$WIRED_CONN"
    printf 'PROFILE_CREATED=%s\n' "$PROFILE_CREATED"
    printf 'PREVIOUS_CONN=%s\n' "$PREVIOUS_CONN"
  } > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$STATE_FILE"
}

nm_connection_exists() {
  [[ -n "${1:-}" ]] && nmcli -g connection.uuid con show "$1" &>/dev/null
}

find_wired_connection() {
  WIRED_CONN=""
  local uuid type ifname addresses fallback="" active_uuid=""
  active_uuid=$(nmcli -g GENERAL.CON-UUID device show "$WIRED_IFACE" 2>/dev/null | head -1 || true)
  if [[ -n "$active_uuid" && "$active_uuid" != "--" ]]; then
    WIRED_CONN="$active_uuid"
    return 0
  fi
  while IFS=: read -r uuid type; do
    [[ "$type" == "802-3-ethernet" || "$type" == "ethernet" ]] || continue
    ifname=$(nmcli -g connection.interface-name con show "$uuid" 2>/dev/null | head -1 || true)
    [[ "$ifname" == "$WIRED_IFACE" ]] || continue
    [[ -n "$fallback" ]] || fallback="$uuid"
    addresses=$(nmcli -g ipv4.addresses con show "$uuid" 2>/dev/null || true)
    if [[ "$addresses" == 172.31.* ]]; then
      WIRED_CONN="$uuid"
      return 0
    fi
  done < <(nmcli -t -f UUID,TYPE con show 2>/dev/null || true)
  WIRED_CONN="$fallback"
  [[ -n "$WIRED_CONN" ]]
}

ensure_wired_connection() {
  load_state
  if [[ "$STATE_WIRED_IFACE" == "$WIRED_IFACE" ]] && nm_connection_exists "$STATE_WIRED_CONN"; then
    WIRED_CONN="$STATE_WIRED_CONN"
    PROFILE_CREATED="$STATE_PROFILE_CREATED"
    PREVIOUS_CONN="$STATE_PREVIOUS_CONN"
    return 0
  fi
  if [[ -n "$STATE_WIRED_IFACE" && "$STATE_WIRED_IFACE" != "$WIRED_IFACE" \
        && "$STATE_PROFILE_CREATED" == true ]] && nm_connection_exists "$STATE_WIRED_CONN"; then
    nmcli con down "$STATE_WIRED_CONN" 2>/dev/null || true
    nmcli con delete "$STATE_WIRED_CONN" >/dev/null
  fi

  PROFILE_CREATED=false
  PREVIOUS_CONN=""

  local current_conn="$WIRED_CONN" current_name="" name="mnnit-campus-$WIRED_IFACE"
  if [[ -n "$current_conn" ]]; then
    current_name=$(nmcli -g connection.id con show "$current_conn" 2>/dev/null | head -1 || true)
  fi
  if [[ "$current_name" == mnnit-wired* || "$current_name" == mnnit-campus-* ]]; then
    [[ "$current_name" == mnnit-campus-* ]] && PROFILE_CREATED=true
    PREVIOUS_CONN=""
    save_state
    return 0
  fi

  PREVIOUS_CONN="$current_conn"
  WIRED_CONN=""
  local uuid type ifname profile_name
  while IFS=: read -r uuid type; do
    [[ "$type" == "802-3-ethernet" || "$type" == "ethernet" ]] || continue
    ifname=$(nmcli -g connection.interface-name con show "$uuid" 2>/dev/null | head -1 || true)
    profile_name=$(nmcli -g connection.id con show "$uuid" 2>/dev/null | head -1 || true)
    if [[ "$ifname" == "$WIRED_IFACE" && "$profile_name" == "$name" ]]; then
      WIRED_CONN="$uuid"
      PROFILE_CREATED=true
      break
    fi
  done < <(nmcli -t -f UUID,TYPE con show 2>/dev/null || true)

  if [[ -z "$WIRED_CONN" ]] && nmcli con add type ethernet ifname "$WIRED_IFACE" con-name "$name" &>/dev/null; then
    while IFS=: read -r uuid type; do
      [[ "$type" == "802-3-ethernet" || "$type" == "ethernet" ]] || continue
      ifname=$(nmcli -g connection.interface-name con show "$uuid" 2>/dev/null | head -1 || true)
      profile_name=$(nmcli -g connection.id con show "$uuid" 2>/dev/null | head -1 || true)
      if [[ "$ifname" == "$WIRED_IFACE" && "$profile_name" == "$name" ]]; then
        WIRED_CONN="$uuid"
        break
      fi
    done < <(nmcli -t -f UUID,TYPE con show 2>/dev/null || true)
    PROFILE_CREATED=true
  fi
  if [[ -n "$WIRED_CONN" ]]; then
    save_state
    ok "Using managed NM profile '$name'"
    return 0
  fi
  warn "Could not create a NetworkManager profile for $WIRED_IFACE."
  return 1
}

detect_iface() {
  local -a ifaces=() campus_ifaces=() carrier_ifaces=() profile_ifaces=()
  local d i uuid type ifname addresses iface=""
  for d in /sys/class/net/*; do
    i="${d##*/}"
    [[ "$i" =~ ^(en|eth) ]] && ifaces+=("$i")
  done
  if [[ ${#ifaces[@]} -eq 0 ]]; then
    warn "No ethernet interface found."
    return 1
  fi

  if [[ -n "$FLAG_INTERFACE" ]]; then
    [[ -d "/sys/class/net/$FLAG_INTERFACE" ]] \
      || { warn "Interface '$FLAG_INTERFACE' does not exist."; return 1; }
    [[ "$FLAG_INTERFACE" =~ ^(en|eth) ]] \
      || { warn "Interface '$FLAG_INTERFACE' is not Ethernet."; return 1; }
    iface="$FLAG_INTERFACE"
  else
    load_state
    if [[ -n "$STATE_WIRED_IFACE" && -d "/sys/class/net/$STATE_WIRED_IFACE" ]]; then
      iface="$STATE_WIRED_IFACE"
    fi
    for i in "${ifaces[@]}"; do
      if ip -4 -o addr show dev "$i" 2>/dev/null | awk '{print $4}' | grep -q '^172\.31\.'; then
        campus_ifaces+=("$i")
      fi
      [[ "$(cat "/sys/class/net/$i/carrier" 2>/dev/null)" == "1" ]] && carrier_ifaces+=("$i")
    done
    if [[ -z "$iface" && ${#campus_ifaces[@]} -eq 1 ]]; then
      iface="${campus_ifaces[0]}"
    elif [[ -z "$iface" && ${#carrier_ifaces[@]} -eq 1 ]]; then
      iface="${carrier_ifaces[0]}"
    fi
    if [[ -z "$iface" && "$NET_BACKEND" == "networkmanager" ]]; then
      while IFS=: read -r uuid type; do
        [[ "$type" == "802-3-ethernet" || "$type" == "ethernet" ]] || continue
        addresses=$(nmcli -g ipv4.addresses con show "$uuid" 2>/dev/null || true)
        [[ "$addresses" == 172.31.* ]] || continue
        ifname=$(nmcli -g connection.interface-name con show "$uuid" 2>/dev/null | head -1 || true)
        if [[ -d "/sys/class/net/$ifname" && " ${profile_ifaces[*]} " != *" $ifname "* ]]; then
          profile_ifaces+=("$ifname")
        fi
      done < <(nmcli -t -f UUID,TYPE con show 2>/dev/null || true)
      [[ ${#profile_ifaces[@]} -ne 1 ]] || iface="${profile_ifaces[0]}"
    fi
    [[ -n "$iface" || ${#ifaces[@]} -ne 1 ]] || iface="${ifaces[0]}"
  fi
  if [[ -z "$iface" ]]; then
    warn "Multiple Ethernet interfaces are possible: ${ifaces[*]}"
    warn "Re-run with --interface IFACE."
    return 1
  fi
  WIRED_IFACE="$iface"

  if [[ "$NET_BACKEND" == "netplan" || "$NET_BACKEND" == "manual" ]]; then
    ok "Interface: $WIRED_IFACE (backend: $NET_BACKEND)"
    WIRED_CONN=""
    return 0
  fi
  local state
  state=$(nmcli -g GENERAL.STATE device show "$WIRED_IFACE" 2>/dev/null || true)
  if [[ "$state" == *unmanaged* ]]; then
    warn "Interface $WIRED_IFACE is unmanaged by NetworkManager."
    if command -v netplan &>/dev/null && [[ -d "${NETPLAN_DIR:-/etc/netplan}" ]]; then
      NET_BACKEND="netplan"
    else
      NET_BACKEND="manual"
    fi
    WIRED_CONN=""
    return 0
  fi
  find_wired_connection || true
  local conn_name=""
  [[ -z "$WIRED_CONN" ]] || conn_name=$(nmcli -g connection.id con show "$WIRED_CONN" 2>/dev/null | head -1 || true)
  ok "Interface: $WIRED_IFACE (connection: ${conn_name:-none})"
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
  [[ "${HOSTEL_PREFIXES[idx]}" == "floorwise" ]] && SELECTED_HOSTEL_FLOORWISE=true || SELECTED_HOSTEL_FLOORWISE=false
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
          ip=$(ask "Enter your room IP" "$SELECTED_HOSTEL_IP")
          if valid_ip "$ip"; then
            SELECTED_HOSTEL_IP="$ip"
            if [[ "$SELECTED_HOSTEL_FLOORWISE" == true ]]; then
              local IFS=. a b c d
              read -r a b c d <<< "$ip"
              SELECTED_HOSTEL_GW="${a}.${b}.${c}.1"
              SELECTED_HOSTEL_PREFIX="24"
              warn "Floor-wise gateway recalculated as $SELECTED_HOSTEL_GW  -  verify it in the summary."
            fi
            break
          fi
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
  [[ "${HOSTEL_PREFIXES[idx]}" == "floorwise" ]] && SELECTED_HOSTEL_FLOORWISE=true || SELECTED_HOSTEL_FLOORWISE=false
  local ip_from="${HOSTEL_FROMS[idx]}" ip_to="${HOSTEL_TOS[idx]}" pdf="${HOSTEL_PDFS[idx]}"

  echo ""
  echo -e "${B}${C}📄  Find your room's IP here (open on phone/PC):${N}"
  echo -e "${C}   $pdf${N}"

  while :; do
    local ip
    ip=$(ask "Enter your room IP (from the PDF above)" "")
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
  if [[ "$NET_BACKEND" == "netplan" ]]; then
    apply_netplan
    return 0
  fi
  if [[ "$NET_BACKEND" == "manual" ]]; then
    print_manual_ip_instructions
    return 0
  fi
  if [[ -z "$WIRED_CONN" ]]; then
    ensure_wired_connection || {
      warn "No NetworkManager connection profile  -  set the IP manually:"
      warn "  nmcli con mod <name> ipv4.method manual ipv4.addresses ${SELECTED_HOSTEL_IP}/${SELECTED_HOSTEL_PREFIX} ipv4.gateway ${SELECTED_HOSTEL_GW} ipv4.dns \"${DNS_SRV_LIST}\""
      return 0
    }
  fi
  local conn_name
  conn_name=$(nmcli -g connection.id con show "$WIRED_CONN" 2>/dev/null | head -1 || true)
  log "Applying static IP on '${conn_name:-$WIRED_CONN}'..."
  nmcli con mod "$WIRED_CONN" \
    connection.autoconnect yes \
    connection.autoconnect-priority 100 \
    ipv4.method manual \
    ipv4.addresses "${SELECTED_HOSTEL_IP}/${SELECTED_HOSTEL_PREFIX}" \
    ipv4.gateway "$SELECTED_HOSTEL_GW" \
    ipv4.dns "$DNS_SRV_LIST" \
    ipv4.routes "${CAMPUS_ROUTE} ${SELECTED_HOSTEL_GW}"
  local carrier
  carrier=$(cat "/sys/class/net/$WIRED_IFACE/carrier" 2>/dev/null || echo 0)
  if [[ "$carrier" == "1" ]]; then
    nmcli con down "$WIRED_CONN" 2>/dev/null >/dev/null || true
    if nmcli con up "$WIRED_CONN"; then
      ok "Static IP applied"
    else
      fail "Connection activation failed  -  check the cable/IP settings"
      return 1
    fi
  else
    # No cable: never activate - avoids phantom "activated" state in NM.
    nmcli con down "$WIRED_CONN" 2>/dev/null >/dev/null || true
    warn "Cable not plugged in  -  config saved; activates at hostel."
  fi
}

# ---- config ownership for packaged units (AUR mihomo runs as its own user) ----
fix_config_ownership() {
  local srv_user srv_group
  srv_user=$(systemctl show mihomo -p User --value 2>/dev/null || true)
  srv_group=$(systemctl show mihomo -p Group --value 2>/dev/null || true)
  if [[ -z "$srv_user" || "$srv_user" == "root" ]]; then
    return 0
  fi
  if [[ -z "$srv_group" ]]; then
    srv_group="$srv_user"
  fi
  if chown "root:$srv_group" /etc/mihomo/config.yaml 2>/dev/null \
     && chmod 640 /etc/mihomo/config.yaml 2>/dev/null \
     && chown "$srv_user:$srv_group" /etc/mihomo 2>/dev/null; then
    ok "Config ownership adjusted for service user '$srv_user'"
  else
    warn "Could not adjust config ownership for '$srv_user'. If mihomo cannot read the config:"
    warn "  sudo chown root:$srv_group /etc/mihomo/config.yaml && sudo chmod 640 /etc/mihomo/config.yaml"
  fi
}

install_rendered_config() {
  local rendered="$1" stage test_dir
  mkdir -p /etc/mihomo
  stage=$(mktemp /etc/mihomo/.config.yaml.XXXXXX)
  test_dir=$(mktemp -d)
  printf '%s\n' "$rendered" > "$stage"
  chmod 600 "$stage"
  cp "$stage" "$test_dir/config.yaml"
  chmod 600 "$test_dir/config.yaml"
  if ! mihomo -t -d "$test_dir" >/dev/null 2>&1; then
    mihomo -t -d "$test_dir" 2>&1 || true
    rm -f "$stage"
    rm -rf "$test_dir"
    die "Config validation failed  -  existing config was not changed"
  fi
  rm -rf "$test_dir"
  CONFIG_HAD_PREVIOUS=false
  rm -f "$CONFIG_BACKUP"
  if [[ -f /etc/mihomo/config.yaml ]]; then
    cp -a /etc/mihomo/config.yaml "$CONFIG_BACKUP"
    CONFIG_HAD_PREVIOUS=true
  fi
  mv "$stage" /etc/mihomo/config.yaml
  chmod 600 /etc/mihomo/config.yaml
  fix_config_ownership
}

restore_previous_config() {
  if [[ "$CONFIG_HAD_PREVIOUS" == true && -f "$CONFIG_BACKUP" ]]; then
    cp -a "$CONFIG_BACKUP" /etc/mihomo/config.yaml
    fix_config_ownership
    warn "Restored the previous mihomo config"
  elif [[ "$CONFIG_HAD_PREVIOUS" != true ]]; then
    rm -f /etc/mihomo/config.yaml
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

  local tun_stack="${FLAG_TUN_STACK:-}"
  if [[ -z "$tun_stack" && -f /etc/mihomo/config.yaml ]]; then
    tun_stack=$(awk '/^tun:/{f=1;next} f && /^  stack:/{print $2; exit}' /etc/mihomo/config.yaml)
  fi
  tun_stack="${tun_stack:-$DEFAULT_TUN_STACK}"
  valid_tun_stack "$tun_stack" \
    || die "Invalid TUN stack '$tun_stack' (use system|gvisor|mixed|mips)"
  local outbound_iface="$WIRED_IFACE"

  local rendered
  rendered=$(python3 - "$proxy_entries" "$proxy_names" "$tun_enable" \
    "$tun_stack" "$outbound_iface" "$TEMPLATE" <<'PYEOF'
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
if "{{" in t:
    raise SystemExit("unrendered config placeholder")
sys.stdout.write(t)
PYEOF
  ) || die "Failed to render config"
  install_rendered_config "$rendered"
  ok "Config updated (tun: $tun_enable)"
}

campus_link() {
  local d i
  for d in /sys/class/net/*; do
    i="${d##*/}"
    [[ "$i" == "lo" ]] && continue
    [[ "$i" == Meta* || "$i" == utun* || "$i" == tun* ]] && continue
    [[ "$(cat "$d/carrier" 2>/dev/null)" == "1" ]] || continue
    if ip -4 -o addr show dev "$i" 2>/dev/null | awk '{print $4}' | grep -q '^172\.31\.'; then
      return 0
    fi
  done
  return 1
}

reconcile_mihomo() {
  if campus_link; then
    if systemctl is-active --quiet mihomo 2>/dev/null; then
      if ! systemctl restart mihomo; then
        fail "mihomo rejected the new config at runtime"
        restore_previous_config
        systemctl restart mihomo 2>/dev/null || true
        return 1
      fi
      ok "mihomo restarted with the new config"
    else
      if ! systemctl start mihomo; then
        fail "mihomo could not start with the new config"
        restore_previous_config
        systemctl start mihomo 2>/dev/null || true
        return 1
      fi
      ok "mihomo started on campus link"
    fi
  else
    systemctl stop mihomo 2>/dev/null || true
    warn "mihomo left stopped until a campus link is active"
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
  local ipv6_default
  ipv6_default=$(ip -6 route show default 2>/dev/null | head -1 || true)
  if [[ -n "$ipv6_default" && "$ipv6_default" != *" dev Meta "* ]]; then
    warn "IPv6 can bypass the proxy: $ipv6_default"
  fi
  echo ""
  if [[ -f /etc/mihomo/config.yaml ]]; then
    echo -e "${B}Proxies in config:${N}"
    grep -oP 'server: \K[0-9.]+' /etc/mihomo/config.yaml | sed 's/^/   /'
  fi
  echo ""
  echo -e "${Y}Note: ping & voice calls don't work through the proxy  -  expected.${N}"
}

reset_nm_profile_to_dhcp() {
  local conn="$1"
  nmcli con mod "$conn" \
    connection.autoconnect yes \
    connection.autoconnect-priority 0 \
    ipv4.method auto \
    ipv4.addresses "" \
    ipv4.gateway "" \
    ipv4.dns "" \
    ipv4.routes "" \
    ipv4.never-default no
}

restore_nm_network() {
  load_state
  local conn="${STATE_WIRED_CONN:-$WIRED_CONN}"
  local created="$STATE_PROFILE_CREATED" previous="$STATE_PREVIOUS_CONN"
  if nm_connection_exists "$conn"; then
    nmcli con down "$conn" 2>/dev/null || true
    if [[ "$created" == true && -n "$previous" ]]; then
      nmcli con delete "$conn" >/dev/null
      ok "Removed the managed campus profile"
    else
      reset_nm_profile_to_dhcp "$conn"
      ok "DHCP restored (campus DNS and routes cleared)"
    fi
  fi
  if nm_connection_exists "$previous"; then
    local previous_iface
    previous_iface=$(nmcli -g connection.interface-name con show "$previous" 2>/dev/null | head -1 || true)
    if [[ -n "$previous_iface" && "$(cat "/sys/class/net/$previous_iface/carrier" 2>/dev/null)" == "1" ]]; then
      nmcli con up "$previous" 2>/dev/null || true
    fi
  elif nm_connection_exists "$conn" \
       && [[ "$(cat "/sys/class/net/$WIRED_IFACE/carrier" 2>/dev/null)" == "1" ]]; then
    nmcli con up "$conn" 2>/dev/null || true
  fi
  rm -f "$STATE_FILE"
}

restore_dhcp() {
  log "Restoring DHCP and stopping proxy..."
  detect_iface || true
  if [[ "$NET_BACKEND" == "networkmanager" ]]; then
    restore_nm_network
  elif [[ -f "$NETPLAN_FILE" ]]; then
    # We wrote a netplan file - remove it and let the existing config take over
    rm -f "$NETPLAN_FILE"
    rm -f "${NETPLAN_FILE}.previous"
    netplan apply 2>/dev/null || true
    ok "DHCP restored (netplan static IP removed)"
  else
    warn "No connection profile found  -  set DHCP manually if needed."
  fi
  systemctl stop mihomo 2>/dev/null || true
  ok "mihomo stopped"
  echo -e "${Y}Run mnnit-proxy-update to restore your campus IP when you return.${N}"
}

toggle_watcher() {
  local file=/etc/NetworkManager/dispatcher.d/90-mihomo-lan
  if [[ "$NET_BACKEND" != "networkmanager" ]]; then
    warn "LAN watcher needs NetworkManager, which is not active on this system."
    return 0
  fi
  if [[ -f "$file" ]]; then
    if confirm "LAN watcher is INSTALLED. Remove it?" "n"; then
      rm -f "$file"
      nmcli general reload 2>/dev/null || true
      systemctl enable mihomo 2>/dev/null || true
      reconcile_mihomo
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
        reconcile_mihomo
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
      detect_iface || die "Could not choose the campus Ethernet interface. Use --interface IFACE."
      pick_hostel
      apply_ip
      gen_config
      reconcile_mihomo
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
      --interface)  [[ $# -lt 2 ]] && die "--interface needs a value"; FLAG_INTERFACE="$2"; shift 2 ;;
      --tun-stack)  [[ $# -lt 2 ]] && die "--tun-stack needs a value"; FLAG_TUN_STACK="$2"; shift 2 ;;
      --non-interactive) FLAG_YES=true; shift ;;
      -h|--help)    sed -n "2,19p" "${BASH_SOURCE[0]:-$0}"; exit 0 ;;
      *)            die "Unknown flag: $1" ;;
    esac
  done
  if [[ -n "$FLAG_TUN_STACK" ]] && ! valid_tun_stack "$FLAG_TUN_STACK"; then
    die "Invalid --tun-stack '$FLAG_TUN_STACK' (use system|gvisor|mixed|mips)"
  fi
}

# Shared by change-ip action and the flag-driven default path.
unattended_change() {
  if ! valid_ip "$FLAG_IP"; then
    die "Invalid --ip '$FLAG_IP'  -  expected four dot-separated octets, e.g. 172.31.64.135"
  fi
  if [[ -n "$FLAG_GATEWAY" ]] && ! valid_ip "$FLAG_GATEWAY"; then
    die "Invalid --gateway '$FLAG_GATEWAY'"
  fi
  SELECTED_HOSTEL_IP="$FLAG_IP"
  if ! resolve_hostel_by_name "$FLAG_HOSTEL"; then exit 1; fi
  derive_network
  detect_iface || die "Could not choose the campus Ethernet interface. Use --interface IFACE."
  apply_ip
  gen_config
  reconcile_mihomo
  ok "Done. Configured for $SELECTED_HOSTEL_NAME."
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
  preflight
  case "$ACTION" in
    change-ip)
      if [[ -z "$FLAG_HOSTEL" || -z "$FLAG_IP" ]]; then
        die "--action change-ip needs --hostel and --ip"
      fi
      unattended_change
      ;;
    dhcp)  restore_dhcp ;;
    status) show_status ;;
    watch) toggle_watcher ;;
    "")
      if [[ "$FLAG_YES" == true && -n "$FLAG_HOSTEL" && -n "$FLAG_IP" ]]; then
        unattended_change
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
