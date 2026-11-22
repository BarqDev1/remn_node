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
    LOCAL_IP=$(curl -4fsS --max-time 3 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)
    echo "=== Настройка RU-релея ($(hostname) / ${LOCAL_IP:-unknown}) ==="
    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qxE 'remnanode|remnawave'; then
        die "На этом сервере работает remnanode/remnawave! Запустите скрипт на RU-релее, а не на VPN-ноде или панели."
    fi
    [[ -n "${EU_IP:-}" ]] || read -rp "IP-адрес европейской ноды (куда пробрасывать трафик): " EU_IP
    is_valid_ipv4 "$EU_IP" || die "Некорректный IPv4-адрес: '${EU_IP}'"
    [[ -z "$LOCAL_IP" || "$EU_IP" != "$LOCAL_IP" ]] || die "EU_IP совпадает с IP этого сервера (${LOCAL_IP})! Запустите скрипт на RU-релее."

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
        local dom_ips
        dom_ips=$(getent ahostsv4 "$SITE_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
        if [[ -n "$LOCAL_IP" ]] && ! grep -qw "$LOCAL_IP" <<< "$dom_ips"; then
            die "DNS ${SITE_DOMAIN} указывает на [${dom_ips:-пусто}], а IP этого сервера — ${LOCAL_IP}. Проверьте DNS (без прокси Cloudflare) или сервер."
        fi
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
    for svc in apache2 caddy haproxy; do
        systemctl is-active --quiet "$svc" 2>/dev/null && systemctl disable --now "$svc" || true
    done
    mkdir -p /etc/systemd/system/nginx.service.d /root/nginx-relay-backup
    cp -a /etc/nginx/sites-enabled /etc/nginx/conf.d /root/nginx-relay-backup/ 2>/dev/null || true
    rm -f /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf
    printf '[Service]\nLimitNOFILE=65535\n' > /etc/systemd/system/nginx.service.d/limits.conf
    systemctl daemon-reload
    grep -qE 'worker_connections\s+[0-9]{1,3};' /etc/nginx/nginx.conf && sed -i -E 's/worker_connections\s+[0-9]+;/worker_connections 8192;/' /etc/nginx/nginx.conf || true
    grep -q 'include /etc/nginx/stream-enabled.conf;' /etc/nginx/nginx.conf || printf '\ninclude /etc/nginx/stream-enabled.conf;\n' >> /etc/nginx/nginx.conf
}

write_decoy_site() {
    mkdir -p /var/www/relay-decoy /var/www/certbot
    cat <<'EOF' > /var/www/relay-decoy/index.html
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <title>АвтоТехСервис — Диагностика, ТО и подбор запчастей</title>
  <meta name="description" content="Компьютерная диагностика, плановое техническое обслуживание и подбор оригинальных и аналоговых автозапчастей по VIN.">
  <style>
    *{box-sizing:border-box}body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#f8fafc;color:#0f172a;line-height:1.55}
    header{background:#0f172a;color:#fff;padding:18px 24px}.wrap{max-width:960px;margin:0 auto}
    .nav{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:12px}.brand{font-weight:700;font-size:18px;letter-spacing:.3px}
    .nav a{color:#cbd5e1;text-decoration:none;font-size:14px;margin-left:18px}.nav a:hover{color:#fff}
    .hero{background:linear-gradient(135deg,#0f172a 0%,#1e293b 100%);color:#f8fafc;padding:56px 24px}
    .hero h1{margin:0 0 12px;font-size:32px;line-height:1.2}.hero p{margin:0;max-width:620px;color:#cbd5e1;font-size:16px}
    main{padding:40px 24px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:20px;margin-top:16px}
    .card{background:#fff;border:1px solid #e2e8f0;border-radius:12px;padding:22px}.card h3{margin:0 0 8px;font-size:17px}.card p{margin:0;color:#475569;font-size:14px}
    .hours{margin-top:32px;background:#fff;border:1px solid #e2e8f0;border-radius:12px;padding:22px;display:flex;justify-content:space-between;flex-wrap:wrap;gap:16px}
    footer{border-top:1px solid #e2e8f0;padding:24px;color:#64748b;font-size:13px;text-align:center}
  </style>
</head>
<body>
  <header><div class="wrap nav"><div class="brand">АвтоТехСервис</div><nav><a href="#services">Услуги</a><a href="#parts">Запчасти</a><a href="#schedule">График</a></nav></div></header>
  <section class="hero"><div class="wrap"><h1>Техническое обслуживание и подбор автозапчастей</h1><p>Компьютерная диагностика электронных систем, плановое ТО, ремонт ходовой части и подбор комплектующих по VIN-номеру для легковых и коммерческих автомобилей.</p></div></section>
  <main class="wrap">
    <h2 id="services">Основные направления</h2>
    <div class="grid">
      <div class="card"><h3>Компьютерная диагностика</h3><p>Чтение и расшифровка кодов неисправностей ЭБУ, проверка датчиков, топливной системы и электрооборудования.</p></div>
      <div class="card"><h3>Плановое ТО</h3><p>Замена моторного масла, фильтров, тормозных колодок, ремней ГРМ и технических жидкостей по регламенту производителя.</p></div>
      <div class="card" id="parts"><h3>Подбор запчастей по VIN</h3><p>Поиск оригинальных деталей и проверенных аналогов с проверкой совместимости по каталогам производителей.</p></div>
    </div>
    <div class="hours" id="schedule">
      <div><strong>График работы</strong><br>Пн–Сб: 09:00 – 20:00 · Вс: выходной</div>
      <div><strong>Запись на обслуживание</strong><br>Предварительная запись по каталогу и VIN-запросу</div>
    </div>
  </main>
  <footer><div class="wrap">© 2026 АвтоТехСервис. Все права защищены.</div></footer>
</body>
</html>
EOF
    cat <<'EOF' > /var/www/relay-decoy/404.html
<!doctype html><html lang="ru"><head><meta charset="utf-8"><title>404 — Страница не найдена</title><style>body{font-family:system-ui,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0;background:#f8fafc;color:#334155}</style></head><body><div><h1>404</h1><p>Запрошенная страница не найдена. <a href="/">На главную</a></p></div></body></html>
EOF
    printf 'User-agent: *\nDisallow:\n' > /var/www/relay-decoy/robots.txt
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
    error_page 404 /404.html;
    location = /404.html { internal; }
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
