# L4 Relay Setup (`setup_ru_relay.sh`)

Interactive setup script for Ubuntu 22.04/24.04 or Debian 12 KVM servers configuring a zero-log L4 relay via Nginx `stream` (SNI router on `:443`) with an optional local HTTPS decoy site (Let's Encrypt TLS 1.3) and optional UDP forwarding.

## Features
- Interactive prompts for remote EU target IP/ports, optional decoy domain, Let's Encrypt email, and SSH port (strict input validation).
- Kernel tuning: `BBR` + `fq` + `net.mptcp.enabled = 0` (`CVE-2026-98432`).
- Nginx `stream` SNI routing on `:443` (`ssl_preread on`, `access_log off`):
  - `SITE_DOMAIN` -> local decoy HTTPS site (`127.0.0.1:8443`, TLS 1.3, auto-renewed Let's Encrypt).
  - All other TLS traffic (including SNI-less) -> transparent L4 forward to target EU node without decryption or VPN keys on the relay.
- Optional UDP forwarding (e.g. `2443` for Hysteria2).
- Idempotent `iptables` firewall (`INPUT DROP`, keeping SSH, `443/tcp`, `80/tcp`, and optional UDP port open).

## Quick Start

Download and inspect the script, then run as `root`:

```bash
curl -fsSL https://raw.githubusercontent.com/BarqDev1/remn_node/main/setup_ru_relay.sh -o /root/setup_ru_relay.sh
sudo bash /root/setup_ru_relay.sh
```

Non-interactive mode:

```bash
sudo EU_IP=203.0.113.10 SITE_DOMAIN=relay.example.com bash /root/setup_ru_relay.sh
```
