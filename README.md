# mnnit-proxy

[![tests](https://github.com/YOUR_USER/mnnit-proxy/actions/workflows/test.yml/badge.svg)](https://github.com/YOUR_USER/mnnit-proxy/actions/workflows/test.yml)

System-wide college proxy for MNNIT Allahabad  -  works for ALL apps, no per-app setup.

Powered by **mihomo** (TUN mode)  -  like Proxifier on Windows, but for Linux.  
Supports Arch and Ubuntu (x86_64 / arm64).

## Quick start

### On campus (LAN plugged in)
```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_USER/mnnit-proxy/main/install.sh | sudo bash
```

If GitHub is blocked on campus, use the proxy to fetch the script:
```bash
curl -x http://edcguest:edcguest@172.31.100.25:3128 -fsSL \
  https://raw.githubusercontent.com/YOUR_USER/mnnit-proxy/main/install.sh | sudo bash
```

### What happens
1. You pick your hostel from a list
2. It prints the official PDF link with room-wise IPs  -  open it on your phone
3. Enter your assigned IP → installer sets up everything
4. After success, every app on your laptop goes through the college proxy automatically

### After install
- `mnnit-proxy-update`  -  change hostel/IP, restore DHCP, toggle LAN auto-watch
- Re-run `install.sh`  -  shows a menu (install / update / diagnose / uninstall)

## What won't work

| Feature | Why | Alternative |
|---|---|---|
| `ping` | ICMP can't pass HTTP proxy | `curl https://google.com` |
| `traceroute` | same |  -  |
| Discord voice / online games | UDP required | TCP-only proxy |
| Torrents / P2P | UDP + inbound blocked |  -  |
| QUIC (HTTP/3) | uses UDP | Browser auto-falls back to TCP |

Everything else (browsers, git, curl, npm, pip, SSH, apt, pacman, etc.) works in ALL apps.

## Hostel IP allotment PDFs

| Hostel | PDF Link |
|--------|----------|
| New Boys A Block | [PDF](https://mnnit.ac.in/images/newstories/2022/ipaddress/IP_List_of_A_Block_Hostel.pdf) |
| New Boys B Block | [PDF](https://mnnit.ac.in/images/newstories/2022/ipaddress/IP_List_of_B_Block_Hostel.pdf) |
| New Boys C Block | [PDF](https://mnnit.ac.in/images/newstories/2022/ipaddress/IP_LIST_of_C_Block_Hostel.pdf) |
| SVBH | [PDF](https://mnnit.ac.in/images/newstories/2022/ipaddress/SVBH_IP_ADDRESS_RANGE.pdf) |
| PG Hostel | [PDF](https://mnnit.ac.in/computercentre/images/ipadd/PG%20Hostel.pdf) |
| Patel Hostel | [PDF](https://mnnit.ac.in/images/newstories/2026/fac_pos/Patel_Hostel_Room_Wise_IP_Allotment.pdf) |
| Tilak Hostel | [PDF](https://mnnit.ac.in/images/newstories/2026/fac_pos/Tilak_Hostel_Room_Wise_IP_Allotment.pdf) |
| Malviya Hostel | [PDF](https://mnnit.ac.in/images/newstories/2026/fac_pos/Malviya_Hostel_new_IP_Allotment_room_wise.pdf) |
| Tandon Hostel | [PDF](https://mnnit.ac.in/images/newstories/2026/fac_pos/Tandon_Hostel_new_IP_Allotment_room_wise.pdf) |
| Tagore Hostel | [PDF](https://mnnit.ac.in/images/newstories/2022/ipaddress/tagore.pdf) |
| Raman Hostel | [PDF](https://mnnit.ac.in/images/newstories/2022/ipaddress/Raman.pdf) |
| KN Girls Hostel | [PDF](https://mnnit.ac.in/images/newstories/2022/ipaddress/KNGH.pdf) |
| SN Girls Hostel | [PDF](https://mnnit.ac.in/images/newstories/2018/SNGH_IP_Allotment.pdf) |
| DJ Girls Hostel | [PDF](https://mnnit.ac.in/images/newstories/2022/ipaddress/DJ_GIRLS_HOSTEL.pdf) |
| International Hostel | [PDF](https://mnnit.ac.in/computercentre/images/ipadd/BF%20&%20IH.pdf) |
| Colony & Quarters | [PDF](https://mnnit.ac.in/computercentre/images/ipadd/Colony.pdf) |

Full list: [MNNIT Computer Centre  -  IP Address Scheme](https://mnnit.ac.in/computercentre/index.php/ip-address-scheme)

## Manual setup

If the installer doesn't work for your distro or network:

1. Install mihomo (Arch: `paru -S mihomo`, Ubuntu: download binary from GitHub releases)
2. Copy `config.template.yaml` to `/etc/mihomo/config.yaml` and fill in proxy IPs
3. Set static IP via nmcli (see `hostels.tsv` for your hostel's gateway/subnet)
4. `sudo systemctl enable --now mihomo`

## Uninstall

```bash
sudo bash install.sh --uninstall
```

## All flags (install.sh)

| Flag | Behavior |
|---|---|
| `--hostel "Name" --ip IP --yes` | Fully unattended install (skips all prompts) |
| `--force` | Proceed even if IP is outside the documented range |
| `--gateway IP` | Override the derived gateway (e.g. SVBH floor-wise subnets) |
| `--skip-ip` | Don't touch nmcli/network settings (CI, self-managed) |
| `--no-tun` | Proxy port only, no TUN device (CI/VM friendly) |
| `--no-lan-watch` | Don't install the LAN auto start/stop watcher |
| `--uninstall` | Remove everything, restore DHCP |
| `--diagnose` | Run diagnostics |

`update.sh` actions: `--action change-ip --hostel N --ip IP --yes` · `--action dhcp` · `--action status` · `--action watch`

## Tests

```bash
bash tests/unit-tests.sh          # syntax, shellcheck, function tests (no root)
sudo bash tests/integration-test.sh   # full unattended install + proxy e2e (Debian/Ubuntu)
bash tests/docker-ubuntu.sh       # same, inside a systemd-enabled Ubuntu container
bash tests/run-tests.sh arch      # Arch binary-install path (root/container)
```

CI runs the same tests on every push: Ubuntu 22.04 + 24.04 (tinyproxy stands in for the college proxy with the same Basic-auth mechanics) plus an Arch container for the binary-install path.

## Structure

```
├── install.sh                  # Complete installer with menu
├── update.sh                   # Fast path: change hostel/IP, restore DHCP
├── config.template.yaml        # Mihomo config template
├── hostels.tsv                 # Hostel data (subnets, gateways, proxies, PDF links)
├── dispatcher/
│   └── 90-mihomo-lan          # NetworkManager dispatcher for LAN auto-watch
└── LICENSE
```

## How it works

**mihomo** creates a TUN virtual network interface. `auto-route` makes all traffic go through it. mihomo then checks the rules:
- Private IPs (10/8, 172.16/12, 192.168/16) → DIRECT (bypasses proxy, stays on campus LAN)
- Everything else → through the college proxy (fallback over 3 proxies)

The `route-exclude-address` blocks in the TUN config prevent mihomo's own proxy connections from looping back into the TUN.

The LAN auto-watch script (`90-mihomo-lan`) monitors the college gateway (`172.31.*`): when you plug into campus LAN, mihomo starts; when you unplug, it stops  -  so hotspot at home just works.