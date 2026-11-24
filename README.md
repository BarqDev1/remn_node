# L4 Relay Setup & Speedtest Decoy Site (`setup_ru_relay.sh`)

Interactive setup script for Ubuntu 22.04/24.04 or Debian 12 KVM servers configuring a zero-log L4 relay via Nginx `stream` (SNI router on `:443`) with a full-featured HTTPS decoy site (including the **ТестНет.рф** speedtest portal) and optional UDP forwarding.

## Features
- Interactive prompts for remote EU target IP/ports, optional decoy domain (including Cyrillic IDN domains like `тестнет.рф` -> automatic Punycode `xn--e1aaxpdcc.xn--p1ai`), Let's Encrypt email, and SSH port.
- Kernel tuning: `BBR` + `cake`/`fq` + 16 MB buffers + `mtu_probing=1` + `net.mptcp.enabled = 0`.
- Nginx `stream` SNI routing on `:443` (`ssl_preread on`, `access_log off`):
  - Strict whitelist (`SNI_MODE=2`): only specified VPN SNI -> EU node; decoy domain, bare IP, and unknown SNI -> local decoy HTTPS site (`127.0.0.1:8443`, TLS 1.2/1.3, HTTP/2).
- **ТестНет.рф Speedtest (`site/`)**:
  - Real multi-stream Download (`/speed/payload-1m.bin`, `/speed/payload-4m.bin` generated from `/dev/urandom`, `gzip off`), real browser Upload (`POST /api/upload` -> local Nginx `204` sink), Ping & Jitter (`/api/ping`), protocol telemetry (`/api/meta`), local history (`localStorage` + CSV export), 24-pulse Ping diagnostic & download time calculator (`network.html`), methodology, FAQ, contacts, and 152-FZ privacy policy.
  - Strict CSP Level 3 (`script-src 'self'; style-src 'self'`), light/dark theme toggle, responsive accessible layout.
- Idempotent `iptables` / `ip6tables` firewall (`INPUT DROP`, keeping SSH, `443/tcp`, `80/tcp`, and optional UDP port open).

## Quick Start (RU VPS)

```bash
curl -fsSL https://raw.githubusercontent.com/BarqDev1/remn_node/main/setup_ru_relay.sh -o /root/setup_ru_relay.sh
sudo bash /root/setup_ru_relay.sh
```

Non-interactive example with `тестнет.рф`:

```bash
sudo EU_IP=203.0.113.10 SITE_DOMAIN="тестнет.рф" SNI_MODE=2 VPN_SNIS="sni1.example.ru" bash /root/setup_ru_relay.sh
```

## Multi-Server Deployment (`*.тестнет.рф`)

You can deploy the same **ТестНет.рф** brand across multiple RU relays using node subdomains (`тестнет.рф`, `msk1.тестнет.рф`, `msk2.тестнет.рф`, `spb1.тестнет.рф`). Each server issues and auto-renews its own Let's Encrypt certificate via HTTP-01, keeps the **ТестНет.рф** brand and `support@тестнет.рф` contacts, and automatically shows its node badge and endpoint (`MSK2`, `SPB1`, etc.):

```bash
sudo EU_IP=203.0.113.11 SITE_DOMAIN="msk2.тестнет.рф" SNI_MODE=2 VPN_SNIS="sni1.example.ru" bash /root/setup_ru_relay.sh
```

## Local Preview & Verification

Start the local preview server (serves `site/` + `/api/ping`, `/api/meta`, `/api/upload`, `/speed/*.bin`):

```bash
python3 scripts/dev_server.py --port 8765
```

Run tests:

```bash
python3 -m unittest -v tests/test_speedtest_site.py
```
