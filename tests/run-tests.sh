#!/usr/bin/env bash
# mnnit-proxy test orchestrator
#
# Modes:
#   unit          -  syntax + shellcheck + function tests (no root needed)
#   integration   -  full unattended install + tinyproxy e2e + dispatcher (needs sudo, Debian/Ubuntu)
#   ci            -  unit + integration (what CI runs)
#   arch          -  unit tests + binary-install path test (run inside an Arch container/machine)
#
# Usage: bash tests/run-tests.sh <mode>
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-unit}"

case "$MODE" in
  unit)
    exec bash "$REPO/tests/unit-tests.sh" "$REPO"
    ;;
  integration)
    exec bash "$REPO/tests/integration-test.sh" "$REPO"
    ;;
  ci)
    bash "$REPO/tests/unit-tests.sh" "$REPO" || exit 1
    exec bash "$REPO/tests/integration-test.sh" "$REPO"
    ;;
  arch)
    echo "── unit tests ──"
    bash "$REPO/tests/unit-tests.sh" "$REPO" || exit 1
    echo ""
    echo "── arch binary-install path ──"
    # Source install.sh functions and exercise the binary fallback directly.
    bash -s "$REPO" <<'ARCH'
set -uo pipefail
REPO="$1"
PASS=0; FAIL=0
t() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "  ✓ $d"; PASS=$((PASS+1)); else echo "  ✗ $d"; FAIL=$((FAIL+1)); fi; }
source "$REPO/install.sh" 2>/dev/null
DISTRO="arch"; DISTRO_FAMILY="arch"
install_mihomo_binary
t "mihomo binary downloaded to /usr/local/bin" test -x /usr/local/bin/mihomo
t "mihomo runs"        /usr/local/bin/mihomo -v
t "unit written"       test -f /etc/systemd/system/mihomo.service
SELECTED_HOSTEL_PROXIES="172.31.100.27,172.31.102.29"
FLAG_NO_TUN=true
mkdir -p /etc/mihomo
gen_config
t "config generated"   test -f /etc/mihomo/config.yaml
t "config validated"   mihomo -t -d /etc/mihomo

echo "── pinned fallback when GitHub API fails ──"
# Mock download(): API requests fail (like rate-limiting), asset downloads
# go through the same mirror chain as the real function (resilient to flaky TLS).
download() {
  if [[ "$1" == *"api.github.com"* ]]; then return 1; fi
  local mirror src
  for mirror in "" "https://ghfast.top/" "https://gh-proxy.com/"; do
    src="${mirror}${1}"
    if curl -fsSL --max-time 30 "$src" -o "$2" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}
rm -f /usr/local/bin/mihomo
install_mihomo_binary
t "binary installed despite API failure" test -x /usr/local/bin/mihomo
V=$(/usr/local/bin/mihomo -v 2>/dev/null | head -1 || true)
case "$V" in
  *"$MIHOMO_PINNED"*) echo "  ✓ pinned version used ($V)"; PASS=$((PASS+1)) ;;
  *) echo "  ✗ pinned version used (got: ${V:-none})"; FAIL=$((FAIL+1)) ;;
esac
echo "ARCH-PASS=$PASS ARCH-FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
exit $(( FAIL > 0 ? 1 : 0 ))
ARCH
    ;;
  *)
    echo "Unknown mode: $MODE (use unit|integration|ci|arch)"
    exit 1
    ;;
esac