#!/usr/bin/env bash
# mnnit-proxy installer  -  system-wide college proxy for MNNIT Allahabad
#
# Usage:
#   sudo bash install.sh                                    # interactive
#   sudo bash install.sh --hostel "New Boys Hostel A Block" \
#                        --ip 172.31.64.135 --yes           # unattended
#   sudo bash install.sh --uninstall
#   sudo bash install.sh --diagnose
#
# Flags:
#   --hostel NAME      hostel name (exact or unique substring)
#   --ip IP            your room IP from the hostel PDF
#   --gateway IP       override the derived gateway (e.g. SVBH floor-wise)
#   --yes              accept all prompts (unattended; needs --hostel + --ip)
#   --force            proceed even if IP is outside the documented range
#   --skip-ip          don't touch nmcli/network settings
#   --no-tun           proxy port only, no TUN device (CI/VM friendly)
#   --no-lan-watch     don't install the LAN auto start/stop watcher
#   --interface IFACE  campus Ethernet interface (required if detection is ambiguous)
#   --tun-stack STACK  system|gvisor|mixed|mips (default: gvisor)
#   --uninstall        remove everything
#   --diagnose         run diagnostics
set -Eeuo pipefail

readonly APP_VERSION="1.2.2"
readonly PROXY_PORT=3128
readonly PROXY_USER="edcguest"
readonly PROXY_PASS="edcguest"
readonly DNS_SRV="172.31.100.6, 172.31.100.7, 172.31.100.8"
readonly DNS_SRV_LIST="172.31.100.6,172.31.100.7,172.31.100.8"
readonly MIHOMO_PINNED="v1.19.30"   # fallback when GitHub API is unavailable
readonly DEFAULT_TUN_STACK="gvisor"

# Data files  -  local dir first, then fallback to downloaded (pipe mode)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || pwd)"
TSV="$SCRIPT_DIR/hostels.tsv"
TEMPLATE="$SCRIPT_DIR/config.template.yaml"
DISPATCHER="$SCRIPT_DIR/dispatcher/90-mihomo-lan"
UPDATE_SH=""   # set by ensure_data in pipe mode (self_install copies it)

WIRED_IFACE=""
WIRED_CONN=""
NET_BACKEND=""   # networkmanager | netplan | manual
SELECTED_HOSTEL_NAME=""
SELECTED_HOSTEL_IP=""
SELECTED_HOSTEL_GW=""
SELECTED_HOSTEL_PREFIX=""
SELECTED_HOSTEL_PROXIES=""
TMPDIR_DATA=""

# ---- flags ----
FLAG_HOSTEL=""
FLAG_IP=""
FLAG_GATEWAY=""
FLAG_FORCE=false
FLAG_YES=false
FLAG_SKIP_IP=false
FLAG_NO_TUN=false
FLAG_NO_LAN_WATCH=false
FLAG_INTERFACE=""
FLAG_TUN_STACK=""

# ---- colors ----
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

# ---- signal handling ----
cleanup() { [[ -n "$TMPDIR_DATA" ]] && rm -rf "$TMPDIR_DATA" 2>/dev/null || true; }
trap cleanup EXIT

# ---- prompt helpers (pipe-safe: read from /dev/tty when available) ----
__tty_read() {
  if [[ -t 0 ]]; then read -r "$@"; return 0; fi
  if [[ -r /dev/tty ]]; then read -r "$@" < /dev/tty; return 0; fi
  return 1   # no interactive input available (CI/non-tty)
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

# ---- IP helpers ----
ip2int() {
  local IFS=. a b c d
  read -r a b c d <<< "$1"
  echo "$((10#$a<<24 | 10#$b<<16 | 10#$c<<8 | 10#$d))"
}

in_range() {
  local ip_i from_i to_i
  ip_i=$(ip2int "$1")
  from_i=$(ip2int "$2")
  to_i=$(ip2int "$3")
  ((ip_i >= from_i && ip_i <= to_i))
}

# Strict: four dot-separated octets, each 0-255 (leading zeros allowed, parsed base-10).
valid_ip() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o
  for o in "${BASH_REMATCH[@]:1}"; do
    (( 10#$o <= 255 )) || return 1
  done
  return 0
}

# ---- download with mirror chain ----
DLOAD_MIRRORS=("" "https://ghfast.top/" "https://gh-proxy.com/" "https://mirror.ghproxy.com/")

download() {
  local url="$1" out="$2" mirror src
  for mirror in "${DLOAD_MIRRORS[@]}"; do
    src="${mirror}${url}"
    if curl -fsSL --connect-timeout 8 --max-time 120 "$src" -o "$out" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# ---- bootstrap internet (try direct, then campus proxy) ----
boot_internet() {
  log "Checking internet connectivity..."
  local ep
  for ep in "https://github.com" "https://www.google.com" "https://1.1.1.1"; do
    if curl -fsSL --max-time 5 -o /dev/null "$ep" 2>/dev/null; then
      ok "Internet working"
      return 0
    fi
  done
  warn "No direct internet  -  trying campus proxy..."
  local proxy_ips=("172.31.100.25" "172.31.100.27" "172.31.100.30" "172.31.102.29")
  local p ip
  for ip in "${proxy_ips[@]}"; do
    p="http://${PROXY_USER}:${PROXY_PASS}@${ip}:${PROXY_PORT}"
    if curl -fsSL --max-time 8 -o /dev/null -x "$p" https://github.com 2>/dev/null; then
      ok "Connected via $ip"
      export http_proxy="$p" https_proxy="$p" HTTP_PROXY="$p" HTTPS_PROXY="$p"
      return 0
    fi
  done
  die "No internet  -  check your connection or run on campus."
}

# ---- fetch data files if running from a pipe ----
ensure_data() {
  if [[ -f "$TSV" && -f "$TEMPLATE" ]]; then
    return 0
  fi
  local base="${REPO_RAW:-https://raw.githubusercontent.com/CC-MNNIT/mnnit-proxy/main}"
  TMPDIR_DATA="$(mktemp -d)"
  log "Running from a pipe  -  downloading data files..."
  download "$base/hostels.tsv" "$TMPDIR_DATA/hostels.tsv" \
    || die "Failed to download hostel data (check REPO_RAW URL)"
  download "$base/config.template.yaml" "$TMPDIR_DATA/config.template.yaml" \
    || die "Failed to download config template"
  download "$base/dispatcher/90-mihomo-lan" "$TMPDIR_DATA/90-mihomo-lan" \
    || warn "Could not download dispatcher  -  LAN watch will be skipped"
  TSV="$TMPDIR_DATA/hostels.tsv"
  TEMPLATE="$TMPDIR_DATA/config.template.yaml"
  DISPATCHER="$TMPDIR_DATA/90-mihomo-lan"
  chmod 755 "$DISPATCHER" 2>/dev/null || true
  # update.sh too, so offline 'mnnit-proxy-update' works for pipe installs
  UPDATE_SH=""
  if download "$base/update.sh" "$TMPDIR_DATA/update.sh"; then
    UPDATE_SH="$TMPDIR_DATA/update.sh"
  else
    warn "Could not download update.sh  -  'mnnit-proxy-update' will need a reinstall"
  fi
}

# ---- distro ----
DISTRO=""
DISTRO_FAMILY=""
detect_distro() {
  if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect OS  -  /etc/os-release not found."
  fi
  local id
  id=$(. /etc/os-release && echo "${ID:-unknown}")
  case "$id" in
    arch|manjaro|endeavouros|archarm|cachyos)      DISTRO="$id"; DISTRO_FAMILY="arch" ;;
    ubuntu|debian|linuxmint|pop|neon)              DISTRO="$id"; DISTRO_FAMILY="debian" ;;
    fedora|rhel|centos|almalinux|rocky|nobara)     DISTRO="$id"; DISTRO_FAMILY="rhel" ;;
    *)                                             DISTRO="$id"; DISTRO_FAMILY="other" ;;
  esac
  log "Detected: $DISTRO ($DISTRO_FAMILY)"
}

# ---- network backend classification ----
# networkmanager  -  NM running, we manage IP + watcher
# netplan         -  no NM, but netplan exists (Ubuntu Server default)
# manual          -  neither: print copy-paste instructions, boot-start mihomo
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

# ---- preflight: fail fast with actionable output, before any questions ----
preflight() {
  log "Checking system requirements..."
  local missing=() cmd
  for cmd in curl python3 ip systemctl; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    fail "Missing required tools: ${missing[*]}"
    local hint
    case "$DISTRO_FAMILY" in
      arch)   hint="sudo pacman -S curl python iproute2 systemd" ;;
      debian) hint="sudo apt install curl python3 iproute2" ;;
      rhel)   hint="sudo dnf install curl python3 iproute" ;;
      *)      hint="install curl, python3 and iproute2 with your package manager" ;;
    esac
    die "Install them first, then re-run:  $hint"
  fi
  ok "Requirements OK"
  detect_backend
  log "Network backend: $NET_BACKEND"
}

# ---- mihomo install ----
install_mihomo() {
  log "Installing mihomo..."
  if command -v mihomo &>/dev/null; then
    ok "mihomo already installed ($(mihomo -v 2>&1 | head -1))"
    return 0
  fi
  case "$DISTRO_FAMILY" in
    arch)          install_mihomo_arch ;;
    debian|rhel)   install_mihomo_binary ;;
    *)             die "Unsupported distro '$DISTRO'  -  see README for manual steps." ;;
  esac
}

install_mihomo_arch() {
  local needed=""
  local pkg
  for pkg in base-devel git; do
    pacman -Qi "$pkg" &>/dev/null || needed="$needed $pkg"
  done
  if [[ -n "$needed" ]]; then
    pacman -S --needed --noconfirm $needed || die "Failed to install:$needed"
  fi
  if ! command -v paru &>/dev/null && ! command -v yay &>/dev/null; then
    log "No AUR helper found  -  building paru..."
    local tmpd user
    tmpd="$(mktemp -d)"
    if ! git clone -c http.proxy="${http_proxy:-}" https://aur.archlinux.org/paru.git "$tmpd/paru"; then
      rm -rf "$tmpd"
      warn "Could not clone AUR  -  falling back to binary install"
      install_mihomo_binary
      return
    fi
    user="${SUDO_USER:-}"
    if [[ -z "$user" || "$user" == "root" ]]; then
      user=$(logname 2>/dev/null || echo "nobody")
    fi
    pushd "$tmpd/paru" >/dev/null
    local build_ok=false
    if command -v runuser &>/dev/null; then
      runuser -u "$user" -- makepkg -si --noconfirm && build_ok=true
    else
      sudo -u "$user" makepkg -si --noconfirm && build_ok=true
    fi
    popd >/dev/null
    rm -rf "$tmpd"
    if [[ "$build_ok" != true ]]; then
      warn "paru build failed  -  falling back to binary install"
      install_mihomo_binary
      return
    fi
  fi
  local helper="paru"
  command -v paru &>/dev/null || helper="yay"
  # paru/yay refuse to run as root  -  drop to the invoking user
  local aur_user="${SUDO_USER:-}"
  if [[ -z "$aur_user" || "$aur_user" == "root" ]]; then
    aur_user=$(logname 2>/dev/null || echo "")
  fi
  local aur_ok=false
  if [[ -n "$aur_user" ]] && id "$aur_user" &>/dev/null; then
    local home_dir
    home_dir=$(getent passwd "$aur_user" 2>/dev/null | cut -d: -f6)
    if runuser -u "$aur_user" -- env HOME="${home_dir:-/tmp}" \
         "$helper" -S --needed --noconfirm mihomo; then
      aur_ok=true
    fi
  fi
  if [[ "$aur_ok" != true ]]; then
    warn "AUR install failed  -  falling back to binary install"
    install_mihomo_binary
    return
  fi
  if [[ -f /usr/lib/systemd/system/mihomo.service ]]; then
    ok "systemd unit from package"
  else
    write_mihomo_unit "/usr/bin/mihomo"
  fi
}

install_mihomo_binary() {
  local arch
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
  log "Downloading latest mihomo binary ($arch)..."
  local tmpd tag=""
  tmpd="$(mktemp -d)"
  if download "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" "$tmpd/release.json" \
     && grep -q '"tag_name"' "$tmpd/release.json"; then
    tag=$(grep '"tag_name"' "$tmpd/release.json" | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
  fi
  if [[ -z "$tag" ]]; then
    tag="$MIHOMO_PINNED"
    warn "GitHub API unavailable  -  using pinned release $tag"
  fi
  local url="https://github.com/MetaCubeX/mihomo/releases/download/${tag}/mihomo-linux-${arch}-${tag}.gz"
  # Retry once - campus/container networks occasionally reset TLS mid-download.
  local ok_dl=false attempt
  for attempt in 1 2; do
    rm -f "$tmpd/mihomo.gz"
    if download "$url" "$tmpd/mihomo.gz" && [[ -s "$tmpd/mihomo.gz" ]]; then
      ok_dl=true
      break
    fi
    [[ "$attempt" == 1 ]] && warn "Download failed - retrying..."
  done
  [[ "$ok_dl" == true ]] || die "Failed to download mihomo binary ($tag)"
  # Stage + validate BEFORE touching the final path (no 0-byte ghosts).
  gunzip -c "$tmpd/mihomo.gz" > "$tmpd/mihomo.bin" 2>/dev/null \
    || die "Downloaded file is not a valid gzip archive"
  install -m 755 "$tmpd/mihomo.bin" /usr/local/bin/mihomo
  rm -rf "$tmpd"
  write_mihomo_unit "/usr/local/bin/mihomo"
  ok "mihomo installed to /usr/local/bin/mihomo"
}

write_mihomo_unit() {
  local bin="$1"
  cat > /etc/systemd/system/mihomo.service <<UNIT
[Unit]
Description=mihomo Daemon, Another Clash Kernel.
Documentation=https://wiki.metacubex.one
After=network.target nss-lookup.target network-online.target

[Service]
Type=simple
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
ExecStart=$bin -d /etc/mihomo
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload 2>/dev/null || true
}

# ---- wired interface detection ----
valid_tun_stack() {
  case "$1" in
    system|gvisor|mixed|mips) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve an existing NetworkManager profile by UUID. Discovery must stay
# read-only: profile creation belongs to apply_ip(), never diagnose/uninstall.
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
  [[ -n "$WIRED_CONN" ]] && return 0
  local name="mnnit-wired-$WIRED_IFACE"
  if nmcli con add type ethernet ifname "$WIRED_IFACE" con-name "$name" &>/dev/null; then
    find_wired_connection || true
    if [[ -n "$WIRED_CONN" ]]; then
      ok "Created NM profile '$name'"
      return 0
    fi
  fi
  warn "Could not create a NetworkManager profile for $WIRED_IFACE."
  return 1
}

detect_iface() {
  log "Detecting wired network interface..."
  local -a ifaces=() campus_ifaces=() carrier_ifaces=() profile_ifaces=()
  local d i uuid type ifname addresses iface=""
  for d in /sys/class/net/*; do
    i="${d##*/}"
    [[ "$i" =~ ^(en|eth) ]] && ifaces+=("$i")
  done
  if [[ ${#ifaces[@]} -eq 0 ]]; then
    warn "No ethernet interface found (en*/eth*)."
    return 1
  fi

  if [[ -n "$FLAG_INTERFACE" ]]; then
    [[ -d "/sys/class/net/$FLAG_INTERFACE" ]] \
      || { warn "Interface '$FLAG_INTERFACE' does not exist."; return 1; }
    [[ "$FLAG_INTERFACE" =~ ^(en|eth) ]] \
      || { warn "Interface '$FLAG_INTERFACE' is not an Ethernet interface."; return 1; }
    iface="$FLAG_INTERFACE"
  else
    for i in "${ifaces[@]}"; do
      if ip -4 -o addr show dev "$i" 2>/dev/null | awk '{print $4}' | grep -q '^172\.31\.'; then
        campus_ifaces+=("$i")
      fi
      if [[ "$(cat "/sys/class/net/$i/carrier" 2>/dev/null)" == "1" ]]; then
        carrier_ifaces+=("$i")
      fi
    done

    if [[ ${#campus_ifaces[@]} -eq 1 ]]; then
      iface="${campus_ifaces[0]}"
    elif [[ ${#carrier_ifaces[@]} -eq 1 ]]; then
      iface="${carrier_ifaces[0]}"
    fi

    # With every cable unplugged, prefer the interface already carrying a
    # saved 172.31.* profile instead of guessing the first sysfs entry.
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
      if [[ ${#profile_ifaces[@]} -eq 1 ]]; then
        iface="${profile_ifaces[0]}"
      fi
    fi

    [[ -n "$iface" || ${#ifaces[@]} -ne 1 ]] || iface="${ifaces[0]}"
  fi

  if [[ -z "$iface" ]]; then
    warn "Multiple Ethernet interfaces are possible: ${ifaces[*]}"
    warn "Re-run with --interface IFACE so the campus proxy cannot use the wrong link."
    return 1
  fi

  WIRED_IFACE="$iface"
  ok "Interface: $WIRED_IFACE"

  if [[ "$NET_BACKEND" == "netplan" || "$NET_BACKEND" == "manual" ]]; then
    warn "NetworkManager not found  -  IP will be set via $([[ "$NET_BACKEND" == "netplan" ]] && echo netplan || echo "manual instructions")."
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
  if [[ -n "$WIRED_CONN" ]]; then
    local conn_name
    conn_name=$(nmcli -g connection.id con show "$WIRED_CONN" 2>/dev/null | head -1 || true)
    ok "NM connection: ${conn_name:-$WIRED_CONN}"
  fi
  return 0
}

# ---- hostel selection ----
# Loads all rows from the TSV into indexed arrays.
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

# Resolves a hostel by exact name (case-insensitive) or unique substring.
# Sets SELECTED_* globals. Returns 1 if not found/ambiguous.
resolve_hostel_by_name() {
  local query="$1" idx
  load_hostels
  local matches=()
  local i
  for i in "${!HOSTEL_NAMES[@]}"; do
    local lname="${HOSTEL_NAMES[i],,}"
    local lquery="${query,,}"
    if [[ "$lname" == "$lquery" || "$lname" == *"$lquery"* ]]; then
      matches+=("$i")
    fi
  done
  if [[ ${#matches[@]} -eq 0 ]]; then
    fail "No hostel matches '$query'."
    echo "Available hostels:" >&2
    for i in "${!HOSTEL_NAMES[@]}"; do echo "  - ${HOSTEL_NAMES[i]}" >&2; done
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

# Derives gateway/prefix after the IP is known (floor-wise handling).
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

# Interactive edit menu; loops until confirmed or cancelled.
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
    echo "  [6] Cancel install"
    echo ""
    local choice
    choice=$(ask "Enter number" "")
    case "$choice" in
      1)
        while :; do
          local ip
          ip=$(ask "Enter your room IP" "$SELECTED_HOSTEL_IP")
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
          local IFS=',' ok_all=true p
          read -ra plist <<< "$pl"
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
      6) die "Cancelled by user." ;;
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

  while :; do
    local ip
    ip=$(ask "Enter your room IP (from the PDF above)" "")
    if [[ -z "$ip" ]]; then
      warn "IP cannot be empty"
      continue
    fi
    if ! valid_ip "$ip"; then
      warn "Not a valid IP address"
      continue
    fi
    if in_range "$ip" "$ip_from" "$ip_to"; then
      SELECTED_HOSTEL_IP="$ip"
      break
    fi
    echo -e "${Y}⚠  $ip is outside ${SELECTED_HOSTEL_NAME}'s documented range (${ip_from}–${ip_to}).${N}"
    if confirm "The college PDF may be outdated. Still use this IP?" "y"; then
      SELECTED_HOSTEL_IP="$ip"
      break
    fi
    echo "Let's try again."
  done

  derive_network

  # Floor-wise subnets (SVBH): the derived gateway is a guess  -  require explicit yes
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

# Unattended selection path (--hostel + --ip + --yes)
unattended_pick() {
  if ! valid_ip "$FLAG_IP"; then
    die "Invalid --ip '$FLAG_IP'  -  expected four dot-separated octets, e.g. 172.31.64.135"
  fi
  if [[ -n "$FLAG_GATEWAY" ]] && ! valid_ip "$FLAG_GATEWAY"; then
    die "Invalid --gateway '$FLAG_GATEWAY'"
  fi
  SELECTED_HOSTEL_IP="$FLAG_IP"
  if ! resolve_hostel_by_name "$FLAG_HOSTEL"; then
    exit 1
  fi
  derive_network
  ok "Unattended: $SELECTED_HOSTEL_NAME  -  $SELECTED_HOSTEL_IP/$SELECTED_HOSTEL_PREFIX via $SELECTED_HOSTEL_GW"
}

# ---- config ownership for packaged units ----
# Distro packages (e.g. the AUR mihomo package) run the daemon as a dedicated
# user instead of root. We write the config root:root 600 - grant the service
# user read access and make /etc/mihomo writable (mihomo stores cache.db
# next to the config). Our own unit (binary install) runs as root: no-op.
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

# True if the config at $2 (default /etc/mihomo/config.yaml) is readable by
# group $1 or world-readable. Pure stat - no privilege needed.
config_group_readable() {
  local grp="${1:-}"
  local path="${2:-/etc/mihomo/config.yaml}"
  local mode cfg_grp
  mode=$(stat -c %a "$path" 2>/dev/null || true)
  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
    return 1
  fi
  if [[ "${mode: -1}" =~ [4567] ]]; then
    return 0
  fi
  if [[ "${mode: -2:1}" =~ [4567] ]]; then
    cfg_grp=$(stat -c %G "$path" 2>/dev/null || true)
    if [[ -n "$grp" && "$cfg_grp" == "$grp" ]]; then
      return 0
    fi
  fi
  return 1
}

# ---- config generation ----
gen_config() {
  log "Generating mihomo config..."
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

  local tun_enable="true"
  if [[ "$FLAG_NO_TUN" == true ]]; then
    tun_enable="false"
  fi

  local tun_stack="${FLAG_TUN_STACK:-$DEFAULT_TUN_STACK}"
  valid_tun_stack "$tun_stack" \
    || die "Invalid TUN stack '$tun_stack' (use system|gvisor|mixed|mips)"
  local outbound_iface="$WIRED_IFACE"

  mkdir -p /etc/mihomo
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
  # Atomic write - an interrupted redirect would leave a truncated config
  printf '%s\n' "$rendered" > /etc/mihomo/config.yaml.tmp
  mv /etc/mihomo/config.yaml.tmp /etc/mihomo/config.yaml
  chmod 600 /etc/mihomo/config.yaml
  fix_config_ownership
  mihomo -t -d /etc/mihomo >/dev/null 2>&1 || {
    mihomo -t -d /etc/mihomo 2>&1 || true
    die "Config validation failed  -  see errors above"
  }
  ok "Config generated and validated (tun: $tun_enable)"
}

# ---- static IP: NM / netplan / manual ----
NETPLAN_FILE="/etc/netplan/99-mnnit-proxy.yaml"

# Print a complete, copy-pasteable block (works pasted into a shell,
# into Google, or into ChatGPT). Values are already filled in.
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
  │       nameservers:
  │         addresses: [${DNS_SRV_LIST//,/ }]
  │ NETPLAN
  │ sudo chmod 600 /etc/netplan/99-mnnit-proxy.yaml
  │ sudo netplan apply
  └────────────── COPY TO HERE ───────────────

  Then verify with:  ip -4 addr show $WIRED_IFACE
  (If your distro does not use netplan, search "set static IP $DISTRO".)
EOF
}

# Render the netplan YAML we would write (used by write_netplan and tests).
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
      nameservers:
        addresses: [${DNS_SRV_LIST//,/ }]
EOF
}

# True if any existing netplan file already configures our interface.
# Scans the directory of NETPLAN_FILE (same base dir in prod and tests).
netplan_iface_conflicts() {
  local base_dir
  base_dir="$(dirname "$NETPLAN_FILE")"
  grep -rlE "(^|[^-[:alnum:]])$WIRED_IFACE:" "$base_dir"/*.yaml 2>/dev/null | head -1
}

apply_netplan() {
  log "Applying static IP via netplan..."
  local conflict
  conflict=$(netplan_iface_conflicts || true)
  if [[ -n "$conflict" ]]; then
    warn "Existing netplan file already configures $WIRED_IFACE: $(basename "$conflict")"
    warn "Not touching it  -  add these values there manually:"
    netplan_yaml | sed 's/^/    /'
    return 0
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
    return 0
  fi
  # Apply failed: roll back our file so the system is not left half-configured
  rm -f "$NETPLAN_FILE"
  warn "netplan apply failed  -  our config was rolled back. Instructions:"
  print_manual_ip_instructions
}

apply_ip() {
  if [[ "$FLAG_SKIP_IP" == true ]]; then
    warn "Skipping network changes (--skip-ip)"
    return 0
  fi
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
  log "Setting static IP on '${conn_name:-$WIRED_CONN}'..."
  nmcli con mod "$WIRED_CONN" \
    ipv4.method manual \
    ipv4.addresses "${SELECTED_HOSTEL_IP}/${SELECTED_HOSTEL_PREFIX}" \
    ipv4.gateway "$SELECTED_HOSTEL_GW" \
    ipv4.dns "$DNS_SRV_LIST"
  local carrier
  carrier=$(cat "/sys/class/net/$WIRED_IFACE/carrier" 2>/dev/null || echo 0)
  if [[ "$carrier" == "1" ]]; then
    nmcli con down "$WIRED_CONN" 2>/dev/null >/dev/null || true
    nmcli con up "$WIRED_CONN" || warn "Connection activation failed  -  check cable"
    ok "Static IP applied"
  else
    # No cable: never activate - a phantom "activated" profile confuses NM
    # (and the user). Config is saved; the dispatcher fires on plug-in.
    nmcli con down "$WIRED_CONN" 2>/dev/null >/dev/null || true
    warn "Cable not plugged in  -  config saved; it activates when you plug in at hostel."
  fi
}

# ---- LAN watcher ----
install_watcher() {
  if [[ "$FLAG_NO_LAN_WATCH" == true ]]; then
    warn "LAN watcher skipped (--no-lan-watch)  -  mihomo will auto-start at boot."
    systemctl enable mihomo 2>/dev/null || true
    return 0
  fi
  if [[ "$NET_BACKEND" != "networkmanager" ]]; then
    warn "NetworkManager not found  -  LAN watcher unavailable (it depends on NM events)."
    systemctl enable mihomo 2>/dev/null || true
    warn "mihomo will start at boot. Going home? Stop it: sudo systemctl stop mihomo"
    return 0
  fi
  if [[ "$FLAG_YES" != true ]]; then
    if ! confirm "Auto-start/stop mihomo when LAN cable plugs/unplugs? (recommended)" "y"; then
      systemctl enable mihomo 2>/dev/null || true
      warn "LAN watcher skipped  -  remember to stop mihomo manually off-campus."
      return 0
    fi
  fi
  if [[ ! -f "$DISPATCHER" ]]; then
    warn "Dispatcher script not found  -  skipping LAN watcher."
    systemctl enable mihomo 2>/dev/null || true
    return 0
  fi
  log "Installing LAN watcher..."
  mkdir -p /etc/NetworkManager/dispatcher.d
  install -m 755 -o root -g root "$DISPATCHER" /etc/NetworkManager/dispatcher.d/90-mihomo-lan
  nmcli general reload 2>/dev/null || systemctl reload NetworkManager 2>/dev/null || true
  systemctl disable mihomo 2>/dev/null || true   # dispatcher owns start/stop now
  ok "LAN watcher installed  -  mihomo starts/stops automatically with campus LAN"
  echo -e "${Y}  ⓘ  Plug in at hostel → start. Unplug or go home → stop.${N}"
}

# True when a live physical interface owns a campus address. Checking the
# address (rather than the preferred default route) survives NetworkManager's
# +20000 connectivity penalty when Wi-Fi is connected at the same time.
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

should_start_mihomo() {
  campus_link
}

# Reconcile immediately instead of waiting for a future dispatcher event.
# This fixes fresh installs (the up event happened before the watcher existed)
# and makes a full reinstall load the newly generated config.
reconcile_mihomo() {
  if campus_link; then
    if systemctl is-active --quiet mihomo 2>/dev/null; then
      systemctl restart mihomo
      ok "mihomo restarted with the new config"
    else
      systemctl start mihomo
      ok "mihomo started on campus link"
    fi
  else
    systemctl stop mihomo 2>/dev/null || true
    echo -e "${Y}  ⓘ  mihomo left stopped - it starts automatically on the campus LAN.${N}"
  fi
}

# ---- verification ----
verify() {
  log "Verifying..."
  echo ""
  if ! campus_link; then
    warn "No live campus link  -  skipping live verification."
    echo -e "${Y}  Plug in at the hostel and the proxy starts automatically.${N}"
    return 0
  fi

  local verification_ok=true
  sleep 2
  if systemctl is-active --quiet mihomo; then
    ok "mihomo service  -  active"
  else
    fail "mihomo service  -  not active"
    verification_ok=false
  fi
  # Packaged units (AUR) run as a dedicated user - config must be readable by it
  local srv_user srv_group
  srv_user=$(systemctl show mihomo -p User --value 2>/dev/null || true)
  srv_group=$(systemctl show mihomo -p Group --value 2>/dev/null || true)
  srv_group="${srv_group:-$srv_user}"
  if [[ -n "$srv_user" && "$srv_user" != "root" ]]; then
    if config_group_readable "$srv_group"; then
      ok "Config readable by service user ($srv_user)"
    else
      fail "Config NOT readable by service user ($srv_user)"
      echo "   Fix: sudo chown root:$srv_group /etc/mihomo/config.yaml && sudo chmod 640 /etc/mihomo/config.yaml"
      verification_ok=false
    fi
  fi
  if [[ "$FLAG_NO_TUN" != true ]]; then
    # Poll up to 10s - TUN device creation can lag on slow machines
    local tun_up=false
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if ip link show Meta &>/dev/null; then tun_up=true; break; fi
      sleep 1
    done
    if [[ "$tun_up" == true ]]; then
      ok "TUN interface  -  present"
    else
      fail "TUN interface  -  not found"
      verification_ok=false
    fi

    # A successful curl alone is not proof of transparency: it can escape via
    # Wi-Fi when TUN routing is absent. Require the kernel lookup to use Meta.
    local tun_route
    tun_route=$(ip route get 1.1.1.1 2>/dev/null | head -1 || true)
    if [[ "$tun_route" == *" dev Meta "* ]]; then
      ok "Transparent route  -  via Meta"
    else
      fail "Transparent route  -  NOT using Meta"
      echo "   route: ${tun_route:-unavailable}"
      verification_ok=false
    fi
  fi
  # Test transparency: bypass any proxy env vars (boot_internet may have
  # exported campus proxy) - if TUN works, plain curl must succeed.
  # In --no-tun mode there is no transparency: reach out via mihomo's port.
  local egress="" ep
  if [[ "$FLAG_NO_TUN" == true ]]; then
    egress=$(curl -fsS --max-time 8 -x "http://127.0.0.1:7890" "https://api.ipify.org" 2>/dev/null || true)
  else
    for ep in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com" "https://ip.sb"; do
      egress=$(curl --noproxy '*' -fsS --max-time 8 "$ep" 2>/dev/null || true)
      [[ -n "$egress" ]] && break
    done
  fi
  if [[ -n "$egress" ]]; then
    ok "Connectivity OK  -  external IP: $egress"
  else
    fail "Direct connectivity check failed"
    verification_ok=false
  fi
  # Proxy chain test (works with or without TUN)
  if curl -fsS --max-time 10 -x "http://127.0.0.1:7890" -o /dev/null https://www.google.com; then
    ok "Proxy chain (127.0.0.1:7890 → upstream)  -  working"
  else
    fail "Proxy chain test failed  -  is the campus proxy reachable?"
    verification_ok=false
  fi

  # The Arch AUR exposed the hostname-vs-IP CONNECT failure that domain
  # sniffing fixes. Keep it an Arch-only required regression check.
  if [[ "${DISTRO_FAMILY:-}" == "arch" && "$FLAG_NO_TUN" != true ]]; then
    if curl --noproxy '*' -fsS --max-time 10 -o /dev/null \
         'https://aur.archlinux.org/rpc?v=5&type=info&arg[]=paru'; then
      ok "AUR RPC through transparent TUN  -  working"
    else
      fail "AUR RPC through transparent TUN failed"
      verification_ok=false
    fi
  fi
  echo ""
  if [[ "$verification_ok" == true ]]; then
    echo -e "${G}${B}┌──────────────────────────────────────────────┐${N}"
    echo -e "${G}${B}│  ✅ DONE  -  internet through college proxy    │${N}"
    echo -e "${G}${B}│  External IP: $egress"
    echo -e "${G}${B}└──────────────────────────────────────────────┘${N}"
    echo ""
    print_limitations
  else
    fail "Verification failed  -  run 'sudo bash install.sh --diagnose' for details."
    return 1
  fi
}

print_limitations() {
  echo -e "${Y}┌─ ⚠ GOOD TO KNOW ─────────────────────────────────────────┐${N}"
  echo -e "${Y}│ The college proxy carries TCP only (same as Proxifier).  │${N}"
  echo -e "${Y}│                                                          │${N}"
  echo -e "${Y}│ ✗ ping google.com        → use curl https://google.com   │${N}"
  echo -e "${Y}│ ✗ traceroute             → ICMP can't pass the proxy     │${N}"
  echo -e "${Y}│ ✗ Discord voice / games  → they need UDP, TCP-only here  │${N}"
  echo -e "${Y}│ ✗ Torrents / P2P         → blocked (UDP + inbound)       │${N}"
  echo -e "${Y}│                                                          │${N}"
  echo -e "${Y}│ Everything else (browsers, git, npm, pip, curl, SSH…)    │${N}"
  echo -e "${Y}│ works normally  -  in ALL apps, no per-app setup.          │${N}"
  echo -e "${Y}└──────────────────────────────────────────────────────────┘${N}"
}

# ---- self-install for offline use ----
self_install() {
  log "Saving toolkit for offline use..."
  mkdir -p /opt/mnnit-proxy
  cp "$TSV" /opt/mnnit-proxy/hostels.tsv
  cp "$TEMPLATE" /opt/mnnit-proxy/config.template.yaml
  local updater="$SCRIPT_DIR/update.sh"
  [[ -f "$updater" ]] || updater="${UPDATE_SH:-}"
  if [[ -f "$updater" ]]; then
    cp "$updater" /opt/mnnit-proxy/update.sh
    chmod +x /opt/mnnit-proxy/update.sh
  fi
  if [[ -f "$DISPATCHER" ]]; then
    cp "$DISPATCHER" /opt/mnnit-proxy/90-mihomo-lan
  fi
  if [[ -f "$SCRIPT_DIR/README.md" ]]; then
    cp "$SCRIPT_DIR/README.md" /opt/mnnit-proxy/README.md
  fi
  cat > /usr/local/bin/mnnit-proxy-update <<'WRAP'
#!/usr/bin/env bash
exec sudo bash /opt/mnnit-proxy/update.sh "$@"
WRAP
  chmod +x /usr/local/bin/mnnit-proxy-update
  ok "Saved to /opt/mnnit-proxy  -  'mnnit-proxy-update' works offline"
}

# ---- diagnostics ----
diagnose() {
  echo -e "${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${B}${C}  mnnit-proxy diagnostics${N}"
  echo -e "${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""
  if systemctl is-active --quiet mihomo 2>/dev/null; then
    ok "mihomo service is running"
  else
    fail "mihomo service is NOT running"
    echo "   Fix: sudo systemctl start mihomo"
  fi
  echo ""
  if ip link show Meta &>/dev/null; then
    ok "TUN interface (Meta) exists"
  else
    warn "TUN interface (Meta) not found (normal with --no-tun or when stopped)"
  fi
  echo ""
  if mihomo -t -d /etc/mihomo >/dev/null 2>&1; then
    ok "Config is valid"
  else
    fail "Config has errors:"
    mihomo -t -d /etc/mihomo 2>&1 | head -5 || true
  fi
  echo ""
  # Ownership vs the service user (AUR package runs as its own user)
  local srv_user srv_group
  srv_user=$(systemctl show mihomo -p User --value 2>/dev/null || true)
  srv_group=$(systemctl show mihomo -p Group --value 2>/dev/null || true)
  srv_group="${srv_group:-$srv_user}"
  if [[ -n "$srv_user" && "$srv_user" != "root" ]]; then
    echo "   Service runs as: $srv_user:$srv_group"
    if config_group_readable "$srv_group"; then
      ok "Config readable by $srv_user"
    else
      fail "Config NOT readable by $srv_user  -  mihomo cannot start"
      echo "   Fix: sudo chown root:$srv_group /etc/mihomo/config.yaml"
      echo "        sudo chmod 640 /etc/mihomo/config.yaml"
      echo "        sudo chown $srv_user:$srv_group /etc/mihomo   # cache.db writes"
    fi
  fi
  echo ""
  detect_iface || true
  if [[ -n "$WIRED_IFACE" ]]; then
    local ip gw carrier
    ip=$(ip -4 addr show "$WIRED_IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
    gw=$(ip route show default dev "$WIRED_IFACE" 2>/dev/null | awk '{print $3; exit}')
    carrier=$(cat "/sys/class/net/$WIRED_IFACE/carrier" 2>/dev/null || echo 0)
    echo "   IP: ${ip:-none}"
    echo "   Gateway: ${gw:-none}"
    if [[ "$carrier" == "1" ]]; then
      ok "Cable connected"
    else
      fail "Cable NOT connected"
    fi
    if [[ "$gw" == 172.31.* ]]; then
      ok "On campus network"
    else
      warn "Gateway is not campus (172.31.*)  -  proxy can't work here"
    fi
  fi
  echo ""
  echo -e "${B}Proxy reachability:${N}"
  local proxies=()
  if [[ -n "$SELECTED_HOSTEL_PROXIES" ]]; then
    local IFS=,
    read -ra proxies <<< "$SELECTED_HOSTEL_PROXIES"
    unset IFS
  elif [[ -f /etc/mihomo/config.yaml ]]; then
    mapfile -t proxies < <(grep -oP 'server: \K[0-9.]+' /etc/mihomo/config.yaml | head -6)
  fi
  local any_reachable=false p
  for p in "${proxies[@]}"; do
    if [[ -z "$p" ]]; then continue; fi
    if timeout 5 bash -c "echo > /dev/tcp/${p}/${PROXY_PORT}" 2>/dev/null; then
      ok "  ${p}:${PROXY_PORT}  -  reachable"
      any_reachable=true
    else
      fail "  ${p}:${PROXY_PORT}  -  UNREACHABLE"
    fi
  done
  echo ""
  if [[ "$any_reachable" == true ]]; then
    local egress=""
    for ep in "https://ifconfig.me" "https://api.ipify.org"; do
      egress=$(curl -fsS --max-time 8 "$ep" 2>/dev/null || true)
      [[ -n "$egress" ]] && break
    done
    if [[ -n "$egress" ]]; then
      ok "Internet works  -  external IP: $egress"
    else
      fail "Internet test failed  -  check: journalctl -u mihomo -n 30"
    fi
  else
    warn "No proxy reachable  -  expected if off campus"
  fi
  echo ""
  echo -e "${Y}Note: ping failing through the proxy is normal  -  use curl instead.${N}"
  echo ""
  ask "Press Enter to continue" ""
}

# ---- uninstall ----
uninstall() {
  log "Uninstalling mnnit-proxy..."
  if [[ "$FLAG_YES" != true ]] && ! confirm "Restore DHCP (remove static IP)?" "y"; then
    :
  else
    detect_iface || true
    if [[ -n "$WIRED_CONN" ]]; then
      nmcli con mod "$WIRED_CONN" ipv4.method auto ipv4.addresses "" ipv4.gateway "" 2>/dev/null || true
      nmcli con up "$WIRED_CONN" 2>/dev/null || true
      ok "DHCP restored"
    fi
  fi
  systemctl stop mihomo 2>/dev/null || true
  systemctl disable mihomo 2>/dev/null || true
  rm -f /etc/NetworkManager/dispatcher.d/90-mihomo-lan
  rm -rf /etc/mihomo
  rm -rf /opt/mnnit-proxy
  rm -f /usr/local/bin/mnnit-proxy-update
  if [[ "$FLAG_YES" == true ]] || confirm "Remove mihomo binary/package?" "n"; then
    # Package-manager-agnostic: pacman package (Arch) or binary install
    # (Debian, Fedora/RHEL, Arch fallback) at /usr/local/bin.
    if command -v pacman &>/dev/null && pacman -Qi mihomo &>/dev/null; then
      # paru/yay refuse to run as root  -  use pacman directly
      pacman -R --noconfirm mihomo 2>/dev/null || true
    elif [[ -x /usr/local/bin/mihomo ]]; then
      rm -f /usr/local/bin/mihomo /etc/systemd/system/mihomo.service
      systemctl daemon-reload 2>/dev/null || true
    fi
  fi
  # netplan file we may have written
  if [[ -f "$NETPLAN_FILE" ]]; then
    rm -f "$NETPLAN_FILE"
    netplan apply 2>/dev/null || true
    ok "netplan static IP removed"
  fi
  nmcli general reload 2>/dev/null || true
  ok "Uninstall complete"
}

# ---- main flows ----
main_install() {
  log "mnnit-proxy installer v$APP_VERSION"
  echo ""
  detect_distro
  preflight
  ensure_data
  boot_internet
  install_mihomo
  if ! detect_iface; then
    if [[ "$FLAG_SKIP_IP" == true ]]; then
      warn "Continuing without a pinned Ethernet interface (--skip-ip)."
    else
      die "Could not choose the campus Ethernet interface. Use --interface IFACE."
    fi
  fi

  if [[ -n "$FLAG_HOSTEL" && -n "$FLAG_IP" && "$FLAG_YES" == true ]]; then
    unattended_pick
  else
    pick_hostel
  fi

  apply_ip
  gen_config
  install_watcher

  # The watcher is installed after apply_ip, so explicitly reconcile once;
  # otherwise a fresh on-campus install can miss the only link-up event.
  reconcile_mihomo
  local verification_ok=true
  verify || verification_ok=false
  self_install
  if [[ "$verification_ok" != true ]]; then
    die "Installation finished, but live verification failed."
  fi
  echo ""
  echo -e "${B}${C}Installation complete!${N}"
  echo -e "${B}Run 'mnnit-proxy-update' to change hostel/IP settings later.${N}"
}

run_update() {
  local updater="$SCRIPT_DIR/update.sh"
  if [[ ! -f "$updater" && -f /opt/mnnit-proxy/update.sh ]]; then
    updater="/opt/mnnit-proxy/update.sh"
  fi
  if [[ ! -f "$updater" ]]; then
    die "update.sh not found  -  reinstall the repo first."
  fi
  exec bash "$updater"
}

show_menu() {
  echo -e "${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${B}${C}  mnnit-proxy v${APP_VERSION}${N}"
  echo -e "${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""
  echo "  [1] Full install / reinstall"
  echo "  [2] Change hostel / IP  (fast, no reinstall)"
  echo "  [3] Diagnose problems"
  echo "  [4] Uninstall"
  echo "  [5] Exit"
  echo ""
  local choice
  choice=$(ask "Enter number" "1")
  case "$choice" in
    1) main_install ;;
    2) run_update ;;
    3) diagnose ;;
    4) detect_distro; detect_iface || true; uninstall ;;
    5) exit 0 ;;
    *) warn "Invalid choice"; show_menu ;;
  esac
}

parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hostel)         [[ $# -lt 2 ]] && die "--hostel needs a value"; FLAG_HOSTEL="$2"; shift 2 ;;
      --ip)             [[ $# -lt 2 ]] && die "--ip needs a value"; FLAG_IP="$2"; shift 2 ;;
      --gateway)        [[ $# -lt 2 ]] && die "--gateway needs a value"; FLAG_GATEWAY="$2"; shift 2 ;;
      --yes|-y)         FLAG_YES=true; shift ;;
      --force)          FLAG_FORCE=true; shift ;;
      --skip-ip)        FLAG_SKIP_IP=true; shift ;;
      --no-tun)         FLAG_NO_TUN=true; shift ;;
      --no-lan-watch)   FLAG_NO_LAN_WATCH=true; shift ;;
      --interface)      [[ $# -lt 2 ]] && die "--interface needs a value"; FLAG_INTERFACE="$2"; shift 2 ;;
      --tun-stack)      [[ $# -lt 2 ]] && die "--tun-stack needs a value"; FLAG_TUN_STACK="$2"; shift 2 ;;
      --non-interactive) FLAG_YES=true; shift ;;
      --uninstall)      FLAG_UNINSTALL=true; shift ;;
      --diagnose)       FLAG_DIAGNOSE=true; shift ;;
      -h|--help)        sed -n "2,23p" "${BASH_SOURCE[0]:-$0}"; exit 0 ;;
      *)                die "Unknown flag: $1" ;;
    esac
  done
  if [[ -n "$FLAG_TUN_STACK" ]] && ! valid_tun_stack "$FLAG_TUN_STACK"; then
    die "Invalid --tun-stack '$FLAG_TUN_STACK' (use system|gvisor|mixed|mips)"
  fi
}

main() {
  parse_flags "$@"
  if [[ "${FLAG_UNINSTALL:-false}" == true ]]; then
    [[ $EUID -eq 0 ]] || die "Run with sudo."
    detect_distro
    detect_iface || true
    uninstall
    return 0
  fi
  if [[ "${FLAG_DIAGNOSE:-false}" == true ]]; then
    [[ $EUID -eq 0 ]] || die "Run with sudo."
    detect_iface || true
    diagnose
    return 0
  fi
  if [[ $EUID -ne 0 ]]; then
    if [[ -n "${BASH_SOURCE[0]}" && "${BASH_SOURCE[0]}" != "-" && -f "${BASH_SOURCE[0]}" && -r /dev/tty ]]; then
      warn "This script needs root. Re-running with sudo..."
      exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
    fi
    die "This script needs root. Run: curl -fsSL <URL> | sudo bash"
  fi
  if command -v mihomo &>/dev/null || [[ -f /etc/mihomo/config.yaml ]]; then
    show_menu
  else
    main_install
  fi
}

# Only run when executed directly  -  allows tests to source this file.
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
