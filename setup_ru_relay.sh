#!/usr/bin/env bash
# Interactive RU Relay (L4 Cascade + optional local HTTPS decoy site) setup.
# Usage: sudo bash setup_ru_relay.sh
# Non-interactive: sudo EU_IP=203.0.113.10 SITE_DOMAIN=relay.example.com bash setup_ru_relay.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Запустите скрипт от root (sudo bash $0)."

is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    read -r a b c d <<< "$ip"
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}
is_valid_port()   { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
is_valid_domain() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; }
is_valid_email()  { [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; }

detect_ssh_port() {
    local p
    p=$(grep -hE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | tail -n 1 || true)
    [[ -n "$p" ]] && is_valid_port "$p" && echo "$p" || echo "22"
}

prompt_inputs() {
    echo "=== Настройка RU-релея (L4-каскад + локальный сайт-заглушка) ==="
    [[ -n "${EU_IP:-}" ]] || read -rp "IP-адрес европейской ноды (куда пробрасывать трафик): " EU_IP
    is_valid_ipv4 "$EU_IP" || die "Некорректный IPv4-адрес: '${EU_IP}'"

    if [[ -z "${EU_TCP_PORT:-}" ]]; then
        read -rp "TCP-порт на европейской ноде [443]: " EU_TCP_PORT
        EU_TCP_PORT="${EU_TCP_PORT:-443}"
    fi
    is_valid_port "$EU_TCP_PORT" || die "Некорректный TCP-порт: '${EU_TCP_PORT}'"

    if [[ -z "${EU_UDP_PORT:-}" ]]; then
        read -rp "UDP-порт для проброса (2443 для Hysteria2, 0 — выкл) [2443]: " EU_UDP_PORT
        EU_UDP_PORT="${EU_UDP_PORT:-2443}"
    fi
    [[ "$EU_UDP_PORT" == "0" ]] || is_valid_port "$EU_UDP_PORT" || die "Некорректный UDP-порт: '${EU_UDP_PORT}'"

    if [[ "${SITE_DOMAIN+x}" != "x" ]]; then
        read -rp "Домен сайта-заглушки на этом RU-сервере (Enter — без сайта, чистый L4): " SITE_DOMAIN
    fi
    SITE_DOMAIN="${SITE_DOMAIN:-}"
    if [[ -n "$SITE_DOMAIN" ]]; then
        is_valid_domain "$SITE_DOMAIN" || die "Некорректный домен: '${SITE_DOMAIN}'"
        if [[ "${LE_EMAIL+x}" != "x" ]]; then
            read -rp "Email для Let's Encrypt (можно оставить пустым): " LE_EMAIL
        fi
        LE_EMAIL="${LE_EMAIL:-}"
        [[ -z "$LE_EMAIL" ]] || is_valid_email "$LE_EMAIL" || die "Некорректный email: '${LE_EMAIL}'"
    fi

    local default_ssh; default_ssh=$(detect_ssh_port)
    if [[ -z "${SSH_PORT:-}" ]]; then
        read -rp "Порт SSH этого сервера (для firewall) [${default_ssh}]: " SSH_PORT
        SSH_PORT="${SSH_PORT:-$default_ssh}"
    fi
    is_valid_port "$SSH_PORT" || die "Некорректный SSH-порт: '${SSH_PORT}'"

    info "EU TCP: ${EU_IP}:${EU_TCP_PORT} | EU UDP: $([[ "$EU_UDP_PORT" != "0" ]] && echo "${EU_IP}:${EU_UDP_PORT}" || echo off) | Decoy: ${SITE_DOMAIN:-off} | SSH: ${SSH_PORT}"
}

configure_sysctl() {
    info "Применяю тюнинг ядра (BBR + net.mptcp.enabled = 0), виртуализация: $(systemd-detect-virt 2>/dev/null || echo unknown)..."
    cat <<'EOF' > /etc/sysctl.d/99-relay.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.mptcp.enabled = 0
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 0
EOF
    sysctl --system >/dev/null 2>&1 || true
    ok "Sysctl: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?'), mptcp=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo 'n/a')"
    ping -c 2 -W 2 "$EU_IP" >/dev/null 2>&1 && ok "ICMP до ${EU_IP}: OK" || warn "ICMP до ${EU_IP} не ответил (продолжаю)."
}

install_packages() {
    info "Устанавливаю nginx, libnginx-mod-stream, certbot, iptables-persistent..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq nginx libnginx-mod-stream certbot curl ca-certificates iptables iptables-persistent
    ok "Пакеты установлены."
}

ensure_iptables_rule() { iptables -C "$@" 2>/dev/null || iptables -A "$@"; }

configure_firewall() {
    info "Настраиваю iptables (SSH ${SSH_PORT}, 443/tcp${SITE_DOMAIN:+, 80/tcp}$([[ "$EU_UDP_PORT" != "0" ]] && echo ", ${EU_UDP_PORT}/udp"))..."
    ensure_iptables_rule INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ensure_iptables_rule INPUT -i lo -j ACCEPT
    ensure_iptables_rule INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
    ensure_iptables_rule INPUT -p tcp --dport 443 -j ACCEPT
    [[ -n "$SITE_DOMAIN" ]] && ensure_iptables_rule INPUT -p tcp --dport 80 -j ACCEPT
    [[ "$EU_UDP_PORT" != "0" ]] && ensure_iptables_rule INPUT -p udp --dport "$EU_UDP_PORT" -j ACCEPT
    iptables -P INPUT DROP
    netfilter-persistent save >/dev/null 2>&1 || (mkdir -p /etc/iptables && iptables-save > /etc/iptables/rules.v4)
    ok "Firewall применён и сохранён."
}

configure_nginx_limits() {
    mkdir -p /etc/systemd/system/nginx.service.d
    printf '[Service]\nLimitNOFILE=65535\n' > /etc/systemd/system/nginx.service.d/limits.conf
    systemctl daemon-reload
    grep -qE 'worker_connections\s+[0-9]{1,3};' /etc/nginx/nginx.conf && sed -i -E 's/worker_connections\s+[0-9]+;/worker_connections 8192;/' /etc/nginx/nginx.conf || true
    grep -q 'include /etc/nginx/stream-enabled.conf;' /etc/nginx/nginx.conf || printf '\ninclude /etc/nginx/stream-enabled.conf;\n' >> /etc/nginx/nginx.conf
    rm -f /etc/nginx/sites-enabled/default
}

write_decoy_site() {
    mkdir -p /var/www/relay-decoy /var/www/certbot
    [[ -f /var/www/relay-decoy/index.html ]] && return 0
    cat <<'EOF' > /var/www/relay-decoy/index.html
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Edge Status</title>
<style>body{margin:0;font-family:system-ui,sans-serif;background:#0f172a;color:#e2e8f0;display:grid;place-items:center;min-height:100vh}main{max-width:440px;padding:28px;border:1px solid #1e293b;border-radius:14px;background:#111827}h1{margin:0 0 8px;font-size:20px}p{margin:0;color:#94a3b8;font-size:14px}.dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#22c55e;margin-right:8px}</style>
</head><body><main><h1><span class="dot"></span>Operational</h1><p>All regional edge services are running normally.</p></main></body></html>
EOF
}

write_http80_server() {
    cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SITE_DOMAIN};
    server_tokens off;
    access_log off;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type text/plain;
    }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
}

obtain_certificate() {
    info "Настраиваю HTTP :80 и выпускаю Let's Encrypt для ${SITE_DOMAIN}..."
    : > /etc/nginx/stream-enabled.conf
    write_http80_server > /etc/nginx/sites-enabled/relay-decoy.conf
    nginx -t
    systemctl enable --now nginx
    systemctl reload nginx

    local email_args=(--register-unsafely-without-email)
    [[ -n "$LE_EMAIL" ]] && email_args=(--email "$LE_EMAIL")
    certbot certonly --webroot -w /var/www/certbot -d "$SITE_DOMAIN" \
        --non-interactive --agree-tos "${email_args[@]}" --keep-until-expiring

    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/usr/bin/env bash\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    ok "Сертификат Let's Encrypt готов."
}

write_final_nginx_configs() {
    if [[ -n "$SITE_DOMAIN" ]]; then
        {
            write_http80_server
            cat <<EOF

server {
    listen 127.0.0.1:8443 ssl http2;
    server_name ${SITE_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${SITE_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.3;
    ssl_ecdh_curve auto;
    ssl_prefer_server_ciphers off;
    ssl_session_tickets off;
    ssl_session_cache shared:RELAY_SSL:10m;
    ssl_session_timeout 1d;

    server_tokens off;
    access_log off;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    root /var/www/relay-decoy;
    index index.html;
    location ~ /\. { return 404; }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
        } > /etc/nginx/sites-enabled/relay-decoy.conf
    else
        rm -f /etc/nginx/sites-enabled/relay-decoy.conf
    fi

    local udp_block=""
    if [[ "$EU_UDP_PORT" != "0" ]]; then
        udp_block="
    server {
        listen 0.0.0.0:${EU_UDP_PORT} udp;
        proxy_pass ${EU_IP}:${EU_UDP_PORT};
        proxy_timeout 60s;
    }"
    fi

    if [[ -n "$SITE_DOMAIN" ]]; then
        cat <<EOF > /etc/nginx/stream-enabled.conf
stream {
    access_log off;
    map \$ssl_preread_server_name \$relay_upstream {
        ${SITE_DOMAIN} 127.0.0.1:8443;
        default        ${EU_IP}:${EU_TCP_PORT};
    }
    server {
        listen 0.0.0.0:443;
        ssl_preread on;
        proxy_pass \$relay_upstream;
        proxy_connect_timeout 10s;
        proxy_timeout 300s;
        tcp_nodelay on;
    }${udp_block}
}
EOF
    else
        cat <<EOF > /etc/nginx/stream-enabled.conf
stream {
    access_log off;
    server {
        listen 0.0.0.0:443;
        proxy_pass ${EU_IP}:${EU_TCP_PORT};
        proxy_connect_timeout 10s;
        proxy_timeout 300s;
        tcp_nodelay on;
    }${udp_block}
}
EOF
    fi
}

activate_relay() {
    local stopped_realm=0
    if systemctl is-active --quiet realm 2>/dev/null; then
        info "Останавливаю старый realm.service для переключения на Nginx stream..."
        systemctl stop realm
        stopped_realm=1
    fi

    info "Проверяю конфигурацию Nginx (nginx -t)..."
    if ! nginx -t; then
        [[ "$stopped_realm" -eq 1 ]] && systemctl start realm || true
        die "nginx -t не прошёл — старый realm восстановлен."
    fi
    [[ "$stopped_realm" -eq 1 ]] && systemctl disable realm || true

    systemctl enable nginx
    systemctl restart nginx
    systemctl is-active --quiet nginx || die "Nginx не запустился (journalctl -u nginx -n 30)."
    ok "Nginx stream relay запущен."
}

verify_result() {
    info "Открытые порты:"
    ss -tulnp | grep -E ":(80|443|${EU_UDP_PORT})\b" || true
    if [[ -n "$SITE_DOMAIN" ]]; then
        local code
        code=$(curl -fsS --max-time 5 --resolve "${SITE_DOMAIN}:443:127.0.0.1" -o /dev/null -w "%{http_code}" "https://${SITE_DOMAIN}/" || echo "FAIL")
        [[ "$code" == "200" ]] && ok "Заглушка https://${SITE_DOMAIN}/ -> HTTP 200 (TLS 1.3 OK)" || warn "Проверка https://${SITE_DOMAIN}/ вернула: ${code}"
    fi
    echo "============================================================"
    ok "RU-релей готов: TCP :443 -> ${EU_IP}:${EU_TCP_PORT}$([[ "$EU_UDP_PORT" != "0" ]] && echo " | UDP :${EU_UDP_PORT} -> ${EU_IP}:${EU_UDP_PORT}")"
    [[ -n "$SITE_DOMAIN" ]] && echo "  Сайт-заглушка: https://${SITE_DOMAIN}/"
    echo "  Remnawave Host: Address=${SITE_DOMAIN:-<IP_RU_VPS>}, Port=443 (SNI как на EU: 77.88.8.1 / домен EU)"
    echo "============================================================"
}

main() {
    prompt_inputs
    configure_sysctl
    install_packages
    configure_firewall
    configure_nginx_limits
    if [[ -n "$SITE_DOMAIN" ]]; then
        write_decoy_site
        obtain_certificate
    fi
    write_final_nginx_configs
    activate_relay
    verify_result
}

main "$@"
