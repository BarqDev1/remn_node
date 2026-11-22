#!/usr/bin/env bash
# Interactive RU Relay (L4 Cascade + stealth multi-page HTTPS site) setup.
# Usage: sudo bash setup_ru_relay.sh
# Non-interactive: sudo EU_IP=203.0.113.10 SITE_DOMAIN=site.example.com SITE_THEME=1 bash setup_ru_relay.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Запустите скрипт от root (sudo bash $0)."

is_valid_ipv4() {
    local ip="$1"; [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'; read -r a b c d <<< "$ip"
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
    echo "=== Настройка сервера ($(hostname) / ${LOCAL_IP:-unknown}) ==="
    if command -v docker >/dev/null 2>&1; then
        docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'remnawave' && die "На этом сервере работает панель remnawave! Останавливаю."
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'remnanode'; then
            warn "Обнаружен контейнер remnanode на $(hostname) (${LOCAL_IP:-?})."
            local ans=""; read -rp "Остановить remnanode и переделать этот сервер в RU-релей? [y/N]: " ans
            [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || die "Отменено."
            docker update --restart=no remnanode >/dev/null 2>&1 || true
            docker stop remnanode >/dev/null 2>&1 || true
            ok "remnanode остановлен и снят с автозапуска."
        fi
    fi

    [[ -n "${EU_IP:-}" ]] || read -rp "IP-адрес европейской ноды (куда пробрасывать трафик): " EU_IP
    is_valid_ipv4 "$EU_IP" || die "Некорректный IPv4-адрес: '${EU_IP}'"
    [[ -z "$LOCAL_IP" || "$EU_IP" != "$LOCAL_IP" ]] || die "EU_IP совпадает с IP этого сервера (${LOCAL_IP})! Запустите скрипт на RU-релее."

    [[ -n "${EU_TCP_PORT:-}" ]] || { read -rp "TCP-порт на европейской ноде [443]: " EU_TCP_PORT; EU_TCP_PORT="${EU_TCP_PORT:-443}"; }
    is_valid_port "$EU_TCP_PORT" || die "Некорректный TCP-порт: '${EU_TCP_PORT}'"
    [[ -n "${EU_UDP_PORT:-}" ]] || { read -rp "UDP-порт для проброса (0 — выкл [макс. стелс], 2443 — Hysteria2) [0]: " EU_UDP_PORT; EU_UDP_PORT="${EU_UDP_PORT:-0}"; }
    [[ "$EU_UDP_PORT" == "0" ]] || is_valid_port "$EU_UDP_PORT" || die "Некорректный UDP-порт: '${EU_UDP_PORT}'"

    [[ "${SITE_DOMAIN+x}" == "x" ]] || read -rp "Домен сайта-заглушки на этом RU-сервере (Enter — без сайта, чистый L4): " SITE_DOMAIN
    SITE_DOMAIN="${SITE_DOMAIN:-}"; SITE_THEME="${SITE_THEME:-}"
    if [[ -n "$SITE_DOMAIN" ]]; then
        is_valid_domain "$SITE_DOMAIN" || die "Некорректный домен: '${SITE_DOMAIN}'"
        local dom_ips; dom_ips=$(getent ahostsv4 "$SITE_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
        if [[ -n "$LOCAL_IP" ]] && ! grep -qw "$LOCAL_IP" <<< "$dom_ips"; then
            die "DNS ${SITE_DOMAIN} указывает на [${dom_ips:-пусто}], а IP этого сервера — ${LOCAL_IP}. Проверьте A-запись (без прокси Cloudflare) или сервер."
        fi
        [[ -n "$SITE_THEME" ]] || { read -rp "Тема сайта: 1) АвтоТехСервис  2) ТехноСистемы (IT)  3) ТрансЛогистик [1]: " SITE_THEME; SITE_THEME="${SITE_THEME:-1}"; }
        [[ "$SITE_THEME" =~ ^[123]$ ]] || die "Некорректная тема: '${SITE_THEME}' (выберите 1, 2 или 3)"
        [[ "${LE_EMAIL+x}" == "x" ]] || read -rp "Email для Let's Encrypt (можно оставить пустым): " LE_EMAIL
        LE_EMAIL="${LE_EMAIL:-}"
        [[ -z "$LE_EMAIL" ]] || is_valid_email "$LE_EMAIL" || die "Некорректный email: '${LE_EMAIL}'"
    fi

    local default_ssh; default_ssh=$(detect_ssh_port)
    [[ -n "${SSH_PORT:-}" ]] || { read -rp "Порт SSH этого сервера (для firewall) [${default_ssh}]: " SSH_PORT; SSH_PORT="${SSH_PORT:-$default_ssh}"; }
    is_valid_port "$SSH_PORT" || die "Некорректный SSH-порт: '${SSH_PORT}'"
    info "EU TCP: ${EU_IP}:${EU_TCP_PORT} | EU UDP: $([[ "$EU_UDP_PORT" != "0" ]] && echo "${EU_IP}:${EU_UDP_PORT}" || echo off) | Сайт: ${SITE_DOMAIN:-off} | SSH: ${SSH_PORT}"
}

configure_sysctl() {
    info "Тюнинг ядра (BBR, mptcp=0, ecn=0), виртуализация: $(systemd-detect-virt 2>/dev/null || echo unknown)..."
    rm -f /etc/sysctl.d/99-relay.conf
    cat <<'EOF' > /etc/sysctl.d/99-network.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.mptcp.enabled = 0
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
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

apply_fw_rules() {
    local bin="$1"
    ensure_rule() { "$bin" -C "$@" 2>/dev/null || "$bin" -A "$@"; }
    ensure_rule INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ensure_rule INPUT -i lo -j ACCEPT
    [[ "$bin" == "ip6tables" ]] && ensure_rule INPUT -p ipv6-icmp -j ACCEPT
    ensure_rule INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
    ensure_rule INPUT -p tcp --dport 443 -j ACCEPT
    [[ -n "$SITE_DOMAIN" ]] && ensure_rule INPUT -p tcp --dport 80 -j ACCEPT
    [[ "$EU_UDP_PORT" != "0" ]] && ensure_rule INPUT -p udp --dport "$EU_UDP_PORT" -j ACCEPT
}

configure_firewall() {
    info "Настраиваю IPv4/IPv6 firewall (SSH ${SSH_PORT}, 443/tcp${SITE_DOMAIN:+, 80/tcp}$([[ "$EU_UDP_PORT" != "0" ]] && echo ", ${EU_UDP_PORT}/udp"))..."
    apply_fw_rules iptables
    iptables -P INPUT DROP
    if command -v ip6tables >/dev/null 2>&1 && [[ -f /proc/net/if_inet6 ]]; then
        apply_fw_rules ip6tables
        ip6tables -P INPUT DROP
    fi
    if ! netfilter-persistent save >/dev/null 2>&1; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6 || true
    fi
    ok "Firewall IPv4/IPv6 применён и сохранён."
}

configure_nginx_limits() {
    for svc in apache2 caddy haproxy; do
        systemctl is-active --quiet "$svc" 2>/dev/null && systemctl disable --now "$svc" || true
    done
    mkdir -p /etc/systemd/system/nginx.service.d /root/nginx-backup
    cp -a /etc/nginx/sites-enabled /etc/nginx/conf.d /root/nginx-backup/ 2>/dev/null || true
    rm -f /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf /etc/nginx/stream-enabled.conf
    printf '[Service]\nLimitNOFILE=65535\n' > /etc/systemd/system/nginx.service.d/limits.conf
    systemctl daemon-reload
    sed -i '/stream-enabled\.conf/d' /etc/nginx/nginx.conf
    grep -qE 'worker_connections\s+[0-9]{1,3};' /etc/nginx/nginx.conf && sed -i -E 's/worker_connections\s+[0-9]+;/worker_connections 8192;/' /etc/nginx/nginx.conf || true
    grep -q 'include /etc/nginx/stream.conf;' /etc/nginx/nginx.conf || printf '\ninclude /etc/nginx/stream.conf;\n' >> /etc/nginx/nginx.conf
}

render_page() {
    local file="$1" title="$2" body="$3"
    cat <<EOF > "/var/www/site/${file}"
<!doctype html><html lang="ru"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title} — ${BRAND}</title><meta name="description" content="${DESC}">
<link rel="icon" href="/favicon.svg" type="image/svg+xml"><link rel="stylesheet" href="/style.css">
</head><body>
<header><div class="w nav"><a class="brand" href="/">${BRAND}</a><nav><a href="/">Главная</a><a href="/services.html">Услуги</a><a href="/about.html">О компании</a><a href="/contacts.html">Контакты</a></nav></div></header>
${body}
<footer><div class="w">© 2026 ${BRAND} · ${SCHED} · <a href="/contacts.html">info@${SITE_DOMAIN}</a></div></footer>
</body></html>
EOF
}

write_site_files() {
    mkdir -p /var/www/site /var/www/certbot
    case "${SITE_THEME:-1}" in
        2) BRAND="ТехноСистемы"; ACCENT="#0f4c81"; DESC="Проектирование корпоративных сетей, обслуживание серверов и СКУД."
           HERO_H="ИТ-инфраструктура и системная интеграция"; HERO_P="Построение отказоустойчивых ЛВС, аудит серверов, IP-телефония и техническое сопровождение офисов."
           C1_H="Сетевые решения"; C1_P="Проектирование СКС, настройка коммутаторов, Wi-Fi и резервирование каналов связи."
           C2_H="Поддержка серверов"; C2_P="Мониторинг, резервное копирование, виртуализация и регламентное обновление систем."
           C3_H="Видеонаблюдение и СКУД"; C3_P="Монтаж и пусконаладка систем контроля доступа и охранного телевидения для бизнеса."
           ABOUT_P="С 2018 года внедряем надёжные инженерные и ИТ-решения для производственных, складских и офисных площадок."; SCHED="Пн–Пт 09:00–19:00"; ADDR="г. Москва, ул. Промышленная, д. 14, офис 308" ;;
        3) BRAND="ТрансЛогистик"; ACCENT="#14532d"; DESC="Сборные грузоперевозки, ответственное хранение и региональная дистрибуция."
           HERO_H="Региональная логистика и складское хранение"; HERO_P="Доставка паллетных и сборных грузов по России, кросс-докинг, маркировка и полный пакет закрывающих документов."
           C1_H="Сборные грузы"; C1_P="Регулярные рейсы между ключевыми терминалами с фиксированным графиком отправок."
           C2_H="Склад класса B+"; C2_P="Стеллажное и напольное хранение, комплектация заказов, инвентаризация и отгрузка по SLA."
           C3_H="Экспедирование"; C3_P="Сопровождение коммерческих партий, контроль температурного режима и страхование перевозок."
           ABOUT_P="Собственный автопарк мало- и среднетоннажного транспорта и автоматизированный учёт движения товарных партий."; SCHED="Пн–Сб 08:00–20:00"; ADDR="г. Подольск, Домодедовское ш., д. 22, стр. 3" ;;
        *) BRAND="АвтоТехСервис"; ACCENT="#1e293b"; DESC="Компьютерная диагностика, плановое ТО и подбор автозапчастей по VIN."
           HERO_H="Техническое обслуживание и подбор запчастей"; HERO_P="Диагностика электронных систем, регламентное ТО, ремонт ходовой части и подбор комплектующих по VIN."
           C1_H="Компьютерная диагностика"; C1_P="Считывание кодов ЭБУ, проверка датчиков, топливной системы и электрооборудования."
           C2_H="Плановое ТО"; C2_P="Замена масла, фильтров, тормозных колодок, ремней ГРМ и технических жидкостей по регламенту."
           C3_H="Подбор по VIN"; C3_P="Поиск оригинальных деталей и сертифицированных аналогов с проверкой совместимости по каталогам."
           ABOUT_P="Работаем с легковыми и коммерческими автомобилями европейских, азиатских и отечественных марок с 2017 года."; SCHED="Пн–Сб 09:00–20:00"; ADDR="г. Москва, Варшавское ш., д. 132А, корп. 2" ;;
    esac

    cat <<EOF > /var/www/site/style.css
*{box-sizing:border-box}body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#f8fafc;color:#0f172a;line-height:1.6}
.w{max-width:960px;margin:0 auto;padding:0 20px}header{background:${ACCENT};color:#fff;padding:16px 0}
.nav{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:12px}.brand{color:#fff;text-decoration:none;font-weight:700;font-size:18px}
nav a{color:#cbd5e1;text-decoration:none;font-size:14px;margin-left:18px}nav a:hover{color:#fff}
.hero{background:linear-gradient(135deg,${ACCENT} 0%,#0f172a 100%);color:#f8fafc;padding:52px 0}.hero h1{margin:0 0 12px;font-size:30px;line-height:1.25}
.hero p{margin:0;max-width:640px;color:#cbd5e1}main{padding:38px 0}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:18px;margin-top:16px}
.card{background:#fff;border:1px solid #e2e8f0;border-radius:10px;padding:20px}.card h3{margin:0 0 8px;font-size:17px}.card p{margin:0;color:#475569;font-size:14px}
table{width:100%;border-collapse:collapse;background:#fff;border:1px solid #e2e8f0;margin-top:16px}th,td{padding:12px 14px;border-bottom:1px solid #e2e8f0;text-align:left;font-size:14px}
footer{border-top:1px solid #e2e8f0;padding:22px 0;color:#64748b;font-size:13px;text-align:center}footer a{color:#475569}
EOF
    printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="6" fill="%s"/><path d="M8 22L16 8l8 14h-4l-4-7-4 7z" fill="#fff"/></svg>\n' "$ACCENT" > /var/www/site/favicon.svg

    render_page "index.html" "Главная" "<section class=\"hero\"><div class=\"w\"><h1>${HERO_H}</h1><p>${HERO_P}</p></div></section><main class=\"w\"><h2>Основные направления</h2><div class=\"grid\"><div class=\"card\"><h3>${C1_H}</h3><p>${C1_P}</p></div><div class=\"card\"><h3>${C2_H}</h3><p>${C2_P}</p></div><div class=\"card\"><h3>${C3_H}</h3><p>${C3_P}</p></div></div></main>"
    render_page "services.html" "Услуги" "<main class=\"w\"><h1>Услуги и регламент</h1><p>${HERO_P}</p><table><tr><th>Направление</th><th>Описание работ</th><th>Срок</th></tr><tr><td>${C1_H}</td><td>${C1_P}</td><td>От 1 рабочего дня</td></tr><tr><td>${C2_H}</td><td>${C2_P}</td><td>По регламенту</td></tr><tr><td>${C3_H}</td><td>${C3_P}</td><td>По согласованию</td></tr></table></main>"
    render_page "about.html" "О компании" "<main class=\"w\"><h1>О компании ${BRAND}</h1><div class=\"card\"><p>${ABOUT_P}</p><p style=\"margin-top:12px\">Работаем с физическими и юридическими лицами по договору с предоставлением гарантийных обязательств и отчётных документов.</p></div></main>"
    render_page "contacts.html" "Контакты" "<main class=\"w\"><h1>Контактная информация</h1><div class=\"grid\"><div class=\"card\"><h3>Адрес</h3><p>${ADDR}</p></div><div class=\"card\"><h3>Режим работы</h3><p>${SCHED}</p></div><div class=\"card\"><h3>Электронная почта</h3><p>info@${SITE_DOMAIN}</p></div></div></main>"
    render_page "404.html" "404" "<main class=\"w\"><h1>404 — Страница не найдена</h1><p>Запрошенный раздел не существует. <a href=\"/\">Вернуться на главную</a>.</p></main>"

    printf 'User-agent: *\nAllow: /\nSitemap: https://%s/sitemap.xml\n' "$SITE_DOMAIN" > /var/www/site/robots.txt
    cat <<EOF > /var/www/site/sitemap.xml
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://${SITE_DOMAIN}/</loc></url><url><loc>https://${SITE_DOMAIN}/services.html</loc></url>
  <url><loc>https://${SITE_DOMAIN}/about.html</loc></url><url><loc>https://${SITE_DOMAIN}/contacts.html</loc></url>
</urlset>
EOF
}

write_http80_server() {
    local v6=""; [[ -f /proc/net/if_inet6 ]] && v6=$'\n    listen [::]:80 default_server;'
    cat <<EOF
server {
    listen 80 default_server;${v6}
    server_name ${SITE_DOMAIN};
    server_tokens off;
    access_log off;
    location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; default_type text/plain; }
    location / { return 301 https://${SITE_DOMAIN}\$request_uri; }
}
EOF
}

obtain_certificate() {
    info "Настраиваю HTTP :80 и выпускаю Let's Encrypt для ${SITE_DOMAIN}..."
    : > /etc/nginx/stream.conf
    write_http80_server > /etc/nginx/sites-enabled/site.conf
    nginx -t && systemctl enable --now nginx && systemctl reload nginx

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
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_ecdh_curve auto;
    ssl_prefer_server_ciphers off;
    ssl_session_tickets off;
    ssl_session_cache shared:WEB_SSL:10m;
    ssl_session_timeout 1d;
    server_tokens off;
    access_log off;
    gzip on;
    gzip_types text/plain text/css application/xml image/svg+xml;
    etag on;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    root /var/www/site;
    index index.html;
    error_page 404 /404.html;
    location = /404.html { internal; }
    location ~* \.(css|svg|ico)$ { expires 7d; add_header Cache-Control "public, max-age=604800"; }
    location ~ /\. { return 404; }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
        } > /etc/nginx/sites-enabled/site.conf
    else
        rm -f /etc/nginx/sites-enabled/site.conf
    fi

    local udp_block="" map_block="" preread="" target="${EU_IP}:${EU_TCP_PORT}"
    if [[ "$EU_UDP_PORT" != "0" ]]; then
        udp_block=$'\n    server { listen 0.0.0.0:'"${EU_UDP_PORT}"$' udp; proxy_pass '"${EU_IP}:${EU_UDP_PORT}"$'; proxy_timeout 60s; }'
    fi
    if [[ -n "$SITE_DOMAIN" ]]; then
        map_block=$'    map $ssl_preread_server_name $backend_upstream {\n        '"${SITE_DOMAIN}"$' 127.0.0.1:8443;\n        default '"${EU_IP}:${EU_TCP_PORT}"$';\n    }\n'
        preread=$'        ssl_preread on;\n'
        target='$backend_upstream'
    fi
    cat <<EOF > /etc/nginx/stream.conf
stream {
    access_log off;
${map_block}    server {
        listen 0.0.0.0:443;
${preread}        proxy_pass ${target};
        proxy_connect_timeout 5s;
        proxy_timeout 300s;
        tcp_nodelay on;
    }${udp_block}
}
EOF
}

activate_relay() {
    local stopped_realm=0
    if systemctl is-active --quiet realm 2>/dev/null; then
        info "Останавливаю старый realm.service..."; systemctl stop realm; stopped_realm=1
    fi
    info "Проверяю конфигурацию Nginx (nginx -t)..."
    if ! nginx -t; then
        [[ "$stopped_realm" -eq 1 ]] && systemctl start realm || true
        die "nginx -t не прошёл — старый realm восстановлен."
    fi
    [[ "$stopped_realm" -eq 1 ]] && systemctl disable realm || true
    systemctl enable nginx && systemctl restart nginx
    systemctl is-active --quiet nginx || die "Nginx не запустился (journalctl -u nginx -n 30)."
    ok "Nginx stream запущен."
}

verify_result() {
    info "Открытые порты:"
    ss -tulnp | grep -E ":(80|443|${EU_UDP_PORT})\b" || true
    if [[ -n "$SITE_DOMAIN" ]]; then
        local path code ok_cnt=0 env_code
        for path in / /services.html /style.css /favicon.svg /robots.txt /sitemap.xml; do
            code=$(curl -fsS --max-time 5 --resolve "${SITE_DOMAIN}:443:127.0.0.1" -o /dev/null -w "%{http_code}" "https://${SITE_DOMAIN}${path}" || echo "FAIL")
            [[ "$code" == "200" ]] && ok_cnt=$((ok_cnt + 1)) || warn "GET ${path} -> ${code}"
        done
        env_code=$(curl -sS --max-time 5 --resolve "${SITE_DOMAIN}:443:127.0.0.1" -o /dev/null -w "%{http_code}" "https://${SITE_DOMAIN}/.env" || echo "FAIL")
        [[ "$ok_cnt" -eq 6 && "$env_code" == "404" ]] && ok "Сайт https://${SITE_DOMAIN}/ прошёл проверку (6/6 HTTP 200, /.env -> 404)" || warn "Проверка сайта: ${ok_cnt}/6 OK, /.env -> ${env_code}"
    fi
    echo "============================================================"
    ok "RU-релей готов: TCP :443 -> ${EU_IP}:${EU_TCP_PORT}$([[ "$EU_UDP_PORT" != "0" ]] && echo " | UDP :${EU_UDP_PORT} -> ${EU_IP}:${EU_UDP_PORT}" || echo " | UDP: выкл")"
    [[ -n "$SITE_DOMAIN" ]] && echo "  Сайт-заглушка: https://${SITE_DOMAIN}/ (многостраничный, TLS 1.2/1.3, HTTP/2)"
    echo "  Remnawave Host: Address=${SITE_DOMAIN:-<IP_RU_VPS>}, Port=443 (SNI как на EU: 77.88.8.1 / домен EU)"
    echo "============================================================"
}

main() {
    prompt_inputs; configure_sysctl; install_packages; configure_firewall; configure_nginx_limits
    [[ -n "$SITE_DOMAIN" ]] && { write_site_files; obtain_certificate; }
    write_final_nginx_configs; activate_relay; verify_result
}
main "$@"
