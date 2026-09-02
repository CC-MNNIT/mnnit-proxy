#!/usr/bin/env bash
# mnnit-proxy installer  -  system-wide college proxy for MNNIT Allahabad
# Usage:  curl -fsSL https://raw.github.com/.../install.sh | sudo bash
#         sudo bash install.sh [--hostel NAME] [--ip IP] [--no-lan-watch]
#         sudo bash install.sh --uninstall
#         sudo bash install.sh --diagnose
set -Eeuo pipefail

readonly VERSION="1.0.0"
readonly PROXY_PORT=3128
readonly PROXY_USER="edcguest"
readonly PROXY_PASS="edcguest"
readonly DNS_SRV="172.31.100.6 172.31.100.7 172.31.100.8"
readonly DNS_SRV_LIST="172.31.100.6,172.31.100.7,172.31.100.8"
readonly DEFAULT_PROXY_LIST="172.31.100.25,172.31.100.27,172.31.100.30"

# Data files  -  local dir first, then fallback to downloaded
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || pwd)"
TSV="$SCRIPT_DIR/hostels.tsv"
TEMPLATE="$SCRIPT_DIR/config.template.yaml"
DISPATCHER="$SCRIPT_DIR/dispatcher/90-mihomo-lan"
WIRED_IFACE=""
WIRED_CONN=""
SELECTED_HOSTEL_NAME=""
SELECTED_HOSTEL_IP=""
SELECTED_HOSTEL_GW=""
SELECTED_HOSTEL_PREFIX=""
SELECTED_HOSTEL_PROXIES=""
PROXY_NAMES=""

# ---- colors ----
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

# ---- signal handling ----
cleanup() {
  [[ -n "${TMPDIR_DATA:-}" ]] && rm -rf "$TMPDIR_DATA" 2>/dev/null
}
trap cleanup EXIT

# ---- prompt helpers (pipe-safe: read from /dev/tty) ----
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

# ---- IP helpers ----
ip2int() {
  local IFS=. a b c d
  read -r a b c d <<< "$1"
  echo "$((a<<24 | b<<16 | c<<8 | d))"
}

int2ip() {
  local n=$1
  echo "$((n>>24 & 255)).$((n>>16 & 255)).$((n>>8 & 255)).$((n & 255))"
}

in_range() {
  local ip="$1" from="$2" to="$3"
  local ip_i from_i to_i
  ip_i=$(ip2int "$ip")
  from_i=$(ip2int "$from")
  to_i=$(ip2int "$to")
  ((ip_i >= from_i && ip_i <= to_i))
}

# ---- download with mirror chain ----
DLOAD_MIRRORS=(
  ""
  "https://ghfast.top/"
  "https://gh-proxy.com/"
  "https://mirror.ghproxy.com/"
)

download() {
  local url="$1" out="$2" extra="${3:-}"
  local mirror src
  for mirror in "${DLOAD_MIRRORS[@]}"; do
    src="${mirror}${url}"
    if curl -fsSL --max-time 15 ${extra:+-x "$extra"} "$src" -o "$out" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# ---- bootstrap internet (try direct, then college proxy) ----
boot_internet() {
  log "Checking internet connectivity..."
  if curl -fsSL --max-time 5 -o /dev/null https://github.com 2>/dev/null; then
    ok "Internet working"
    return 0
  fi
  # Try a few endpoints
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

# ---- fetch data files if running from pipe ----
ensure_data() {
  if [[ -f "$TSV" && -f "$TEMPLATE" ]]; then
    return 0
  fi
  local base="${REPO_RAW:-https://raw.githubusercontent.com/YOUR_USER/mnnit-proxy/main}"
  TMPDIR_DATA="$(mktemp -d)"
  log "Downloading data files from repo..."
  download "$base/hostels.tsv" "$TMPDIR_DATA/hostels.tsv" \
    || die "Failed to download hostel data (check repo URL)"
  download "$base/config.template.yaml" "$TMPDIR_DATA/config.template.yaml" \
    || die "Failed to download config template"
  download "$base/dispatcher/90-mihomo-lan" "$TMPDIR_DATA/dispatcher" \
    || warn "Could not download dispatcher  -  will skip LAN watch"
  TSV="$TMPDIR_DATA/hostels.tsv"
  TEMPLATE="$TMPDIR_DATA/config.template.yaml"
  DISPATCHER="$TMPDIR_DATA/dispatcher"
  chmod 755 "$DISPATCHER" 2>/dev/null || true
}

# ---- detect distro ----
DISTRO=""
DISTRO_FAMILY=""
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    local id
    id=$(grep ^ID= /etc/os-release | cut -d= -f2 | tr -d '"')
    case "$id" in
      arch|manjaro|endeavouros|archarm) DISTRO="arch"; DISTRO_FAMILY="arch" ;;
      ubuntu|debian|linuxmint|pop) DISTRO="$id"; DISTRO_FAMILY="debian" ;;
      *) DISTRO="$id"; DISTRO_FAMILY="other" ;;
    esac
  else
    die "Cannot detect OS  -  /etc/os-release not found."
  fi
  log "Detected: $DISTRO ($DISTRO_FAMILY)"
}

# ---- install mihomo ----
install_mihomo() {
  log "Installing mihomo..."
  if command -v mihomo &>/dev/null; then
    ok "mihomo already installed ($(mihomo -v 2>&1 | head -1))"
    return 0
  fi
  case "$DISTRO_FAMILY" in
    arch)
      install_mihomo_arch
      ;;
    debian)
      install_mihomo_debian
      ;;
    *)
      die "Unsupported distro  -  see README for manual install steps."
      ;;
  esac
}

install_mihomo_arch() {
  local needed=0
  for pkg in base-devel git; do
    pacman -Qi "$pkg" &>/dev/null || needed=1
  done
  if (( needed )); then
    pacman -S --needed --noconfirm base-devel git || die "Failed to install base-devel"
  fi
  if ! command -v paru &>/dev/null && ! command -v yay &>/dev/null; then
    log "No AUR helper found  -  building paru..."
    local tmpd
    tmpd="$(mktemp -d)"
    pushd "$tmpd" >/dev/null
    git clone -c http.proxy="${http_proxy:-}" https://aur.archlinux.org/paru.git || {
      # Fallback: binary install
      popd >/dev/null; rm -rf "$tmpd"
      install_mihomo_binary; return
    }
    cd paru
    # makepkg must run as non-root
    local user="${SUDO_USER:-${USER:-$(whoami)}}"
    if [[ "$user" == "root" ]]; then
      user=$(logname 2>/dev/null || echo "nobody")
    fi
    if command -v runuser &>/dev/null; then
      runuser -u "$user" -- makepkg -si --noconfirm
    else
      sudo -u "$user" makepkg -si --noconfirm
    fi || {
      popd >/dev/null; rm -rf "$tmpd"
      warn "paru build failed  -  falling back to binary install"
      install_mihomo_binary; return
    }
    popd >/dev/null; rm -rf "$tmpd"
  fi
  local helper="paru"
  command -v paru &>/dev/null || helper="yay"
  $helper -S --needed --noconfirm mihomo || {
    warn "AUR install failed  -  falling back to binary install"
    install_mihomo_binary; return
  }
  # The AUR package ships mihomo.service
  if [[ -f /usr/lib/systemd/system/mihomo.service ]]; then
    ok "systemd unit from package"
  else
    write_mihomo_unit
  fi
}

install_mihomo_debian() {
  install_mihomo_binary
}

install_mihomo_binary() {
  local arch
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    armv7l)  arch="armv7" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
  log "Downloading latest mihomo binary ($arch)..."
  local tag asset url tmpd
  tmpd="$(mktemp -d)"
  # Fetch latest release info
  download "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest" "$tmpd/release.json" \
    || die "Failed to fetch latest mihomo release info"
  tag=$(python3 -c "import json; print(json.load(open('$tmpd/release.json'))['tag_name'])" 2>/dev/null \
    || grep '"tag_name"' "$tmpd/release.json" | head -1 | sed 's/.*"tag_name": "\(.*\)",/\1/')
  asset="mihomo-linux-${arch}-${tag}.gz"
  url="https://github.com/MetaCubeX/mihomo/releases/download/${tag}/${asset}"
  download "$url" "$tmpd/mihomo.gz" || die "Failed to download mihomo binary"
  gunzip -c "$tmpd/mihomo.gz" > /usr/local/bin/mihomo
  chmod +x /usr/local/bin/mihomo
  rm -rf "$tmpd"
  write_mihomo_unit
  ok "mihomo installed to /usr/local/bin/mihomo"
}

write_mihomo_unit() {
  cat > /etc/systemd/system/mihomo.service <<'UNIT'
[Unit]
Description=mihomo Daemon, Another Clash Kernel.
Documentation=https://wiki.metacubex.one
After=network.target nss-lookup.target network-online.target

[Service]
Type=simple
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
ExecStart=/usr/bin/env mihomo -d /etc/mihomo
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
}

# ---- detect wired interface ----
detect_iface() {
  log "Detecting wired network interface..."
  local ifaces
  ifaces=($(ls /sys/class/net 2>/dev/null | grep -E '^(en|eth)' || true))
  if [[ ${#ifaces[@]} -eq 0 ]]; then
    warn "No ethernet interface found (en*/eth*)."
    return 1
  fi
  local i iface
  for i in "${ifaces[@]}"; do
    if [[ "$(cat /sys/class/net/$i/carrier 2>/dev/null)" == "1" ]]; then
      iface="$i"; break
    fi
  done
  iface="${iface:-${ifaces[0]}}"
  WIRED_IFACE="$iface"
  ok "Interface: $WIRED_IFACE"
  # Get NM connection name
  WIRED_CONN=$(nmcli -g GENERAL.CONNECTION device show "$WIRED_IFACE" 2>/dev/null | head -1)
  if [[ -z "$WIRED_CONN" ]]; then
    # Try to find the active connection for this device
    WIRED_CONN=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep ":$WIRED_IFACE$" | cut -d: -f1 | head -1)
  fi
  if [[ -z "$WIRED_CONN" ]]; then
    WIRED_CONN=$(nmcli -t -f NAME,TYPE con show 2>/dev/null | grep ':802-3-ethernet' | cut -d: -f1 | head -1)
  fi
  if [[ -n "$WIRED_CONN" ]]; then
    ok "NM connection: $WIRED_CONN"
  else
    warn "No NetworkManager ethernet connection profile found."
  fi
}

# ---- hostel picker ----
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
  # Print grouped
  local prev_group="" idx=0
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
  local idx=$((choice-1))
  SELECTED_HOSTEL_NAME="${names[idx]}"
  SELECTED_HOSTEL_GW="${gws[idx]}"
  SELECTED_HOSTEL_PREFIX="${prefixes[idx]}"
  SELECTED_HOSTEL_PROXIES="${proxses[idx]}"
  local pdf="${pdfs[idx]}"
  local ip_from="${froms[idx]}" ip_to="${tos[idx]}"

  echo ""
  echo -e "${B}${C}📄  Find your room's IP here:${N}"
  echo -e "${C}   $pdf${N}"
  echo -e "${Y}   Press Enter after you've opened it and found your IP.${N}"
  echo ""
  ask "Press Enter to continue" ""

  while :; do
    local ip
    ip=$(ask "Enter the assigned IP from the PDF" "")
    if [[ -z "$ip" ]]; then
      warn "IP cannot be empty"
      continue
    fi
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      warn "Not a valid IP address"
      continue
    fi
    if in_range "$ip" "$ip_from" "$ip_to"; then
      SELECTED_HOSTEL_IP="$ip"
      break
    else
      echo -e "${Y}⚠  $ip is outside ${SELECTED_HOSTEL_NAME}'s documented range (${ip_from}–${ip_to}).${N}"
      if confirm "The college PDF may be outdated. Still use this IP?" "y"; then
        SELECTED_HOSTEL_IP="$ip"
        break
      else
        echo "Let's try again."
      fi
    fi
  done

  # Compute gateway for floorwise hostels
  if [[ "$SELECTED_HOSTEL_GW" == "floorwise" ]]; then
    # Derive gateway from /24 of the entered IP
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

# ---- generate mihomo config ----
gen_config() {
  log "Generating mihomo config..."
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
  PROXY_NAMES="$proxy_names"

  # Render template by replacing {{PLACEHOLDERS}} with python3 (handles newlines).
  # envsubst can't be used here because PROXY_ENTRIES contains YAML blocks easily,
  # and sed chokes on multi-line replacement.
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
  # Validate
  mihomo -t -d /etc/mihomo 2>&1 || die "Config validation failed  -  check /etc/mihomo/config.yaml"
  ok "Config generated and validated"
}

# ---- configure static IP ----
apply_ip() {
  if [[ -z "$WIRED_CONN" ]]; then
    warn "No NetworkManager connection found  -  skipping static IP config."
    warn "Set your IP manually: nmcli con mod <name> ipv4.method manual ipv4.addresses IP/prefix ipv4.gateway GW ipv4.dns \"$DNS_SRV\""
    return
  fi
  log "Setting static IP..."
  nmcli con mod "$WIRED_CONN" \
    ipv4.method manual \
    ipv4.addresses "${SELECTED_HOSTEL_IP}/${SELECTED_HOSTEL_PREFIX}" \
    ipv4.gateway "$SELECTED_HOSTEL_GW" \
    ipv4.dns "$DNS_SRV_LIST"
  # Check carrier (cable plugged?)
  local carrier
  carrier=$(cat /sys/class/net/"$WIRED_IFACE"/carrier 2>/dev/null || echo 0)
  if [[ "$carrier" == "1" ]]; then
    nmcli con down "$WIRED_CONN" 2>/dev/null || true
    nmcli con up "$WIRED_CONN" 2>/dev/null || warn "Connection activation failed  -  check cable?"
    ok "Static IP applied"
  else
    warn "Cable not plugged in  -  saved IP config. It will activate when you plug in at hostel."
    # Try to reactivate anyway (nmcli up will fail gracefully)
    nmcli con up "$WIRED_CONN" 2>/dev/null || true
  fi
}

# ---- install LAN watcher ----
install_watcher() {
  if ! confirm "Auto-start/stop mihomo when LAN cable plugs/unplugs?" "y"; then
    warn "LAN watcher skipped  -  remember to stop mihomo manually when off campus."
    systemctl enable mihomo 2>/dev/null || true
    return
  fi
  if [[ ! -f "$DISPATCHER" ]]; then
    warn "Dispatcher script not found  -  skipping LAN watcher."
    systemctl enable mihomo 2>/dev/null || true
    return
  fi
  log "Installing LAN watcher..."
  mkdir -p /etc/NetworkManager/dispatcher.d
  cp "$DISPATCHER" /etc/NetworkManager/dispatcher.d/90-mihomo-lan
  chown root:root /etc/NetworkManager/dispatcher.d/90-mihomo-lan
  chmod 755 /etc/NetworkManager/dispatcher.d/90-mihomo-lan
  # Reload NM config (not restart, to avoid dropping connections)
  nmcli general reload 2>/dev/null || systemctl reload NetworkManager 2>/dev/null || true
  # Disable mihomo boot autostart  -  dispatcher controls lifecycle
  systemctl disable mihomo 2>/dev/null || true
  ok "LAN watcher installed  -  mihomo starts/stops automatically with campus LAN"
  echo -e "${Y}  ⓘ  Behavior: plug in at hostel → start proxy. Unplug or go home → stop.${N}"
}

# ---- verify ----
verify() {
  log "Verifying..."
  echo ""
  local carrier=0
  carrier=$(cat /sys/class/net/"$WIRED_IFACE"/carrier 2>/dev/null || echo 0)
  if [[ "$carrier" != "1" ]]; then
    warn "LAN cable not plugged in  -  skipping live verification."
    echo -e "${Y}  The proxy will work when you plug in at hostel.${N}"
    echo -e "${Y}  Run 'sudo systemctl start mihomo' or just plug the cable.${N}"
    return
  fi
  # 1. Service
  sleep 2
  if systemctl is-active --quiet mihomo; then ok "mihomo service  -  active"
  else fail "mihomo service  -  not active"; fi
  # 2. TUN
  if ip link show Meta &>/dev/null || ip link show utun &>/dev/null; then ok "TUN interface  -  present"
  else fail "TUN interface  -  not found"; fi
  # 3. Egress IP
  local egress=""
  for ep in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com" "https://ip.sb"; do
    egress=$(curl -fsS --max-time 8 "$ep" 2>/dev/null || true)
    [[ -n "$egress" ]] && break
  done
  if [[ -n "$egress" ]]; then ok "External IP: $egress"
  else fail "External IP check failed"
  fi
  # 4. Google
  if curl -fsS --max-time 10 -o /dev/null https://google.com 2>/dev/null; then ok "Google  -  reachable"
  else fail "Google  -  not reachable"
  fi
  echo ""
  if [[ -n "$egress" ]]; then
    echo -e "${G}${B}┌──────────────────────────────────────────┐${N}"
    echo -e "${G}${B}│  ✅ DONE  -  internet through college proxy  │${N}"
    echo -e "${G}${B}│  External IP: $egress${N}"
    echo -e "${G}${B}└──────────────────────────────────────────┘${N}"
    echo ""
    print_limitations
    echo ""
    echo -e "${B}Commands:${N}"
    echo -e "  mnnit-proxy-update   (change hostel/IP later)"
    echo -e "  journalctl -u mihomo -f  (live logs)"
    echo -e "  cat /opt/mnnit-proxy/README  (offline help)"
  else
    warn "Verification incomplete  -  check cable and rerun 'sudo bash install.sh --diagnose'"
  fi
}

print_limitations() {
  echo -e "${Y}┌─ ⚠ GOOD TO KNOW ─────────────────────────────────────────┐${N}"
  echo -e "${Y}│ The college proxy carries TCP only (same as Proxifier).   │${N}"
  echo -e "${Y}│                                                          │${N}"
  echo -e "${Y}│ ✗ ping google.com            → use curl https://google.com ${N}"
  echo -e "${Y}│ ✗ traceroute                 → ICMP can't pass the proxy  ${N}"
  echo -e "${Y}│ ✗ Discord voice / online     → need UDP, TCP-only here    ${N}"
  echo -e "${Y}│ ✗ Torrents / P2P             → blocked (UDP + inbound)    ${N}"
  echo -e "${Y}│                                                          ${N}"
  echo -e "${Y}│ Everything else (browsers, git, npm, pip, SSH…) works    ${N}"
  echo -e "${Y}│ automatically in ALL apps  -  no per-app setup needed.     ${N}"
  echo -e "${Y}└──────────────────────────────────────────────────────────┘${N}"
}

# ---- self-install to /opt ----
self_install() {
  log "Saving toolkit for offline use..."
  mkdir -p /opt/mnnit-proxy
  cp "$TSV" /opt/mnnit-proxy/hostels.tsv 2>/dev/null || true
  cp "$TEMPLATE" /opt/mnnit-proxy/config.template.yaml 2>/dev/null || true
  local updater="${SCRIPT_DIR}/update.sh"
  if [[ -f "$updater" ]]; then
    cp "$updater" /opt/mnnit-proxy/update.sh
    chmod +x /opt/mnnit-proxy/update.sh
  fi
  [[ -f "$DISPATCHER" ]] && cp "$DISPATCHER" /opt/mnnit-proxy/90-mihomo-lan 2>/dev/null || true
  # Create wrapper
  cat > /usr/local/bin/mnnit-proxy-update <<'WRAP'
#!/usr/bin/env bash
exec sudo bash /opt/mnnit-proxy/update.sh "$@"
WRAP
  chmod +x /usr/local/bin/mnnit-proxy-update
  ok "Toolkit saved to /opt/mnnit-proxy"
  ok "Run 'mnnit-proxy-update' anytime to change hostel/IP"
}

# ---- diagnose ----
diagnose() {
  echo -e "${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${B}${C}  mnnit-proxy diagnostics${N}"
  echo -e "${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""
  # 1. Service
  if systemctl is-active --quiet mihomo 2>/dev/null; then
    ok "mihomo service is running"
  else
    fail "mihomo service is NOT running"
    echo "   Fix: sudo systemctl start mihomo"
  fi
  echo ""
  # 2. TUN
  if ip link show Meta &>/dev/null; then
    ok "TUN interface (Meta) exists"
  else
    fail "TUN interface (Meta) not found"
    echo "   Fix: mihomo may not have started  -  check logs: journalctl -u mihomo -n 20"
  fi
  echo ""
  # 3. Config valid
  if mihomo -t -d /etc/mihomo 2>&1 | grep -q "test is successful"; then
    ok "Config is valid"
  else
    fail "Config has errors"
    mihomo -t -d /etc/mihomo 2>&1
  fi
  echo ""
  # 4. Interface
  detect_iface || true
  if [[ -n "$WIRED_IFACE" ]]; then
    local ip gw
    ip=$(ip -4 addr show "$WIRED_IFACE" 2>/dev/null | grep inet | awk '{print $2}' | head -1)
    gw=$(ip route show default dev "$WIRED_IFACE" 2>/dev/null | awk '{print $3}')
    echo "   IP: ${ip:-none}"
    echo "   Gateway: ${gw:-none}"
    if ip link show "$WIRED_IFACE" 2>/dev/null | grep -q "state UP"; then
      local carrier
      carrier=$(cat /sys/class/net/"$WIRED_IFACE"/carrier 2>/dev/null || echo 0)
      if [[ "$carrier" == "1" ]]; then ok "Cable connected"
      else fail "Cable NOT connected"
      fi
    else
      fail "Interface $WIRED_IFACE is down"
    fi
  fi
  echo ""
  # 5. Proxy reachability
  echo -e "${B}Proxy reachability:${N}"
  local IFS=',' proxies=($SELECTED_HOSTEL_PROXIES)
  if [[ ${#proxies[@]} -eq 0 ]]; then
    # Try to read from config
    local proxy_line
    proxy_line=$(grep -oP 'server: \K[0-9.]+' /etc/mihomo/config.yaml 2>/dev/null | head -5 || true)
    if [[ -n "$proxy_line" ]]; then
      IFS=$'\n' proxies=($proxy_line)
    else
      proxies=("172.31.100.25" "172.31.100.27" "172.31.100.30")
    fi
  fi
  local any_reachable=0
  for p in "${proxies[@]}"; do
    p=$(echo "$p" | xargs)
    if timeout 5 bash -c "echo > /dev/tcp/${p}/${PROXY_PORT}" 2>/dev/null; then
      ok "  ${p}:${PROXY_PORT}  -  reachable"
      any_reachable=1
    else
      fail "  ${p}:${PROXY_PORT}  -  UNREACHABLE"
    fi
  done
  echo ""
  # 6. Internet test
  if (( any_reachable )); then
    local egress=""
    for ep in "https://ifconfig.me" "https://api.ipify.org"; do
      egress=$(curl -fsS --max-time 8 "$ep" 2>/dev/null || true)
      [[ -n "$egress" ]] && break
    done
    if [[ -n "$egress" ]]; then
      ok "Internet works  -  external IP: $egress"
    else
      fail "Internet test failed"
      echo "   Check: journalctl -u mihomo -n 30 | tail -20"
    fi
  else
    warn "No proxy reachable  -  internet test skipped (expected if off campus)"
  fi
  echo ""
  echo -e "${Y}${B}Note: ping fails through proxy  -  that's normal. Use curl to test.${N}"
  echo ""
  ask "Press Enter to continue" ""
}

# ---- uninstall ----
uninstall() {
  log "Uninstalling..."
  if confirm "Restore DHCP (remove static IP)?" "y"; then
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
  if [[ "$DISTRO_FAMILY" == "debian" ]]; then
    if confirm "Remove mihomo binary?" "n"; then
      rm -f /usr/local/bin/mihomo
      rm -f /etc/systemd/system/mihomo.service
      systemctl daemon-reload
    fi
  fi
  if [[ "$DISTRO_FAMILY" == "arch" ]]; then
    if confirm "Remove mihomo package?" "n"; then
      paru -R --noconfirm mihomo 2>/dev/null || yay -R --noconfirm mihomo 2>/dev/null || true
    fi
  fi
  nmcli general reload 2>/dev/null || true
  ok "Uninstall complete"
}

# ---- main flow ----
main_install() {
  log "mnnit-proxy installer v$VERSION"
  echo ""
  ensure_data
  boot_internet
  detect_distro
  install_mihomo
  detect_iface
  pick_hostel
  apply_ip
  # Generate config before start so service has valid config
  gen_config
  install_watcher
  # Start mihomo (if LAN watcher is installed, it starts on cable up; but also start now if cable connected)
  if systemctl is-enabled mihomo 2>/dev/null | grep -q "enabled"; then
    systemctl enable --now mihomo 2>/dev/null || true
  else
    # Dispatcher mode  -  try starting now if campus
    systemctl start mihomo 2>/dev/null || true
  fi
  verify
  self_install
  echo ""
  echo -e "${B}${C}Installation complete!${N}"
  echo -e "${B}Run 'mnnit-proxy-update' to change hostel/IP settings later.${N}"
}

# ---- menu (re-run) ----
show_menu() {
  echo -e "${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo -e "${B}${C}  mnnit-proxy v${VERSION}${N}"
  echo -e "${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"
  echo ""
  echo "  [1] Full install / reinstall"
  echo "  [2] Change hostel / IP  (fast, no reinstall)"
  echo "  [3] Diagnose problems"
  echo "  [4] Uninstall"
  echo "  [5] Exit"
  echo ""
  local choice=$(ask "Enter number" "1")
  case "$choice" in
    1) main_install ;;
    2) run_update ;;
    3) diagnose ;;
    4) uninstall ;;
    5) exit 0 ;;
    *) warn "Invalid choice"; show_menu ;;
  esac
}

run_update() {
  local updater="${SCRIPT_DIR}/update.sh"
  if [[ -f "$updater" ]]; then
    exec bash "$updater" "$@"
  elif [[ -f /opt/mnnit-proxy/update.sh ]]; then
    exec bash /opt/mnnit-proxy/update.sh "$@"
  else
    die "update.sh not found  -  reinstall the repo or run: curl -fsSL <URL>/update.sh | sudo bash"
  fi
}

# ---- entry point ----
if (( EUID != 0 )); then
  # Running from a pipe  -  ask to re-exec with sudo
  echo -e "${Y}This script needs root privileges.${N}"
  echo -e "${Y}Please run: ${B}curl -fsSL <URL> | sudo bash${N}"
  exit 0
fi

# Parse flags
FLAG_HOSTEL=""
FLAG_IP=""
FLAG_NO_LAN_WATCH=false
FLAG_UNINSTALL=false
FLAG_DIAGNOSE=false
FLAG_YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostel)      shift; FLAG_HOSTEL="$1" ;;
    --ip)          shift; FLAG_IP="$1" ;;
    --no-lan-watch) FLAG_NO_LAN_WATCH=true ;;
    --uninstall)   FLAG_UNINSTALL=true ;;
    --diagnose)    FLAG_DIAGNOSE=true ;;
    --yes)         FLAG_YES=true ;;
    *)             echo "Unknown flag: $1"; exit 1 ;;
  esac
  shift
done

if $FLAG_UNINSTALL; then
  detect_distro
  detect_iface
  uninstall
  exit 0
fi
if $FLAG_DIAGNOSE; then
  detect_iface
  diagnose
  exit 0
fi

# Check if mihomo is already installed (systemd unit or binary exists)
if command -v mihomo &>/dev/null || [[ -f /etc/mihomo/config.yaml ]]; then
  show_menu
else
  main_install
fi