#!/usr/bin/env bash
# Interactive RU Relay (L4 Cascade + stealth multi-page HTTPS site) setup.
# Usage: sudo bash setup_ru_relay.sh
# Multi-profile (несколько IP/направлений на одном сервере): sudo bash setup_ru_relay.sh --profiles /root/relay-profiles.conf
# Non-interactive examples:
#   sudo EU_IP=203.0.113.10 SITE_DOMAIN="тестнет.рф" SNI_MODE=2 VPN_SNIS="sni1.example.ru sni2.example.ru" bash setup_ru_relay.sh
#   sudo EU_IP="2001:db8::1 2001:db8::2 2001:db8::3" SITE_DOMAIN=site.example.com SNI_MODE=2 VPN_SNIS="sni1.example.ru sni2.example.ru" bash setup_ru_relay.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

is_valid_ipv4() {
    local ip="$1"; [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'; read -r a b c d <<< "$ip"
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 ))
}
is_valid_ipv6() {
    local ip="$1"
    [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import ipaddress, sys; ipaddress.IPv6Address(sys.argv[1])' "$ip" 2>/dev/null
        return $?
    fi
    return 0
}
is_valid_ip()     { is_valid_ipv4 "$1" || is_valid_ipv6 "$1"; }
is_valid_port()   { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
is_valid_domain() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; }
normalize_domain() {
    local raw="$1"
    raw="${raw#https://}"; raw="${raw#http://}"; raw="${raw%%/*}"; raw="${raw%.}"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$raw" <<'PYEOF'
import sys
dom = sys.argv[1].strip().lower()
ascii_dom = dom.encode("idna").decode("ascii")
disp_dom = ascii_dom.encode("ascii").decode("idna")
print(f"{ascii_dom}\t{disp_dom}")
PYEOF
        return $?
    fi
    local lower
    lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    if command -v idn2 >/dev/null 2>&1; then
        local asc
        asc=$(idn2 "$lower") || return 1
        printf '%s\t%s\n' "$asc" "$lower"
        return 0
    fi
    printf '%s\t%s\n' "$lower" "$lower"
}
is_valid_sni_pattern() { is_valid_domain "${1#.}"; }
is_valid_email()  { [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; }

detect_ssh_port() {
    local p
    p=$(grep -hE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}' | tail -n 1 || true)
    [[ -n "$p" ]] && is_valid_port "$p" && echo "$p" || echo "22"
}

port_in_use_tcp() {
    ss -tlpn 2>/dev/null | grep -qE "[:.]${1}\s"
}

parse_eu_ips() {
    local raw="${EU_IP:-}"
    raw="${raw//,/ }"
    EU_IPS=()
    EU_TARGET_HOSTS=()
    EU_HAS_IPV6=0
    local tok seen=""
    for tok in $raw; do
        tok="${tok#[}"; tok="${tok%]}"
        is_valid_ip "$tok" || die "Некорректный IPv4/IPv6-адрес: '${tok}'"
        if [[ " ${seen} " == *" ${tok} "* ]]; then
            continue
        fi
        seen+=" ${tok}"
        EU_IPS+=("$tok")
        if is_valid_ipv6 "$tok"; then
            EU_HAS_IPV6=1
            EU_TARGET_HOSTS+=("[${tok}]")
        else
            EU_TARGET_HOSTS+=("${tok}")
        fi
    done
    (( ${#EU_IPS[@]} >= 1 )) || die "Не указан ни один IP-адрес европейской ноды."
    EU_IP="${EU_IPS[0]}"
    EU_TARGET_HOST="${EU_TARGET_HOSTS[0]}"
    if is_valid_ipv6 "$EU_IP"; then
        EU_IS_IPV6=1
    else
        EU_IS_IPV6=0
    fi
}

prompt_inputs() {
    LOCAL_IP=$(curl -4fsS --max-time 3 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true)
    echo "============================================================"
    echo "  Настройка RU-релея ($(hostname) / ${LOCAL_IP:-unknown})"
    echo "============================================================"

    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qE '^(remnanode|remnawave)$'; then
        info "На сервере обнаружен контейнер remnanode/remnawave — скрипт продолжит работу и аккуратно проверит порты."
    fi

    [[ -n "${EU_IP:-}" ]] || read -rp "IP европейской ноды (IPv4/IPv6; можно пул через пробел/запятую — 1-й станет основным для UDP): " EU_IP
    parse_eu_ips
    if [[ "$EU_HAS_IPV6" -eq 1 ]]; then
        ip -6 addr show scope global 2>/dev/null | grep -q inet6 || warn "На этом RU-сервере не найден глобальный IPv6 — проверьте связность до ${EU_IPS[*]}."
    fi

    [[ -n "${EU_TCP_PORT:-}" ]] || { read -rp "TCP-порт на европейской ноде [443]: " EU_TCP_PORT; EU_TCP_PORT="${EU_TCP_PORT:-443}"; }
    is_valid_port "$EU_TCP_PORT" || die "Некорректный TCP-порт: '${EU_TCP_PORT}'"

    [[ -n "${LISTEN_PORT:-}" ]] || { read -rp "Входной TCP-порт на этом сервере [443]: " LISTEN_PORT; LISTEN_PORT="${LISTEN_PORT:-443}"; }
    is_valid_port "$LISTEN_PORT" || die "Некорректный входной порт: '${LISTEN_PORT}'"

    LISTEN_IP="${LISTEN_IP:-}"
    if [[ -n "$LISTEN_IP" ]]; then
        is_valid_ipv4 "$LISTEN_IP" || die "Некорректный IPv4 для LISTEN_IP: '${LISTEN_IP}'"
        local own_ips
        own_ips=$(ip -o -4 addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
        grep -qx "$LISTEN_IP" <<< "$own_ips" || warn "IP ${LISTEN_IP} не найден на интерфейсах этого сервера (nginx не сможет на него привязаться; за NAT укажите внутренний адрес)."
    fi

    local ip_item
    for ip_item in "${EU_IPS[@]}"; do
        if [[ -n "$LOCAL_IP" && "$ip_item" == "$LOCAL_IP" && "$LISTEN_PORT" == "$EU_TCP_PORT" ]]; then
            die "Петля трафика: ${LOCAL_IP}:${LISTEN_PORT} -> ${ip_item}:${EU_TCP_PORT}. Укажите IP европейской ноды или другой порт."
        fi
    done

    [[ -n "${EU_UDP_PORT:-}" ]] || { read -rp "UDP-порт для проброса (0 — выкл [макс. стелс], 443 — Hysteria2) [0]: " EU_UDP_PORT; EU_UDP_PORT="${EU_UDP_PORT:-0}"; }
    [[ "$EU_UDP_PORT" == "0" ]] || is_valid_port "$EU_UDP_PORT" || die "Некорректный UDP-порт: '${EU_UDP_PORT}'"

    [[ "${SITE_DOMAIN+x}" == "x" ]] || read -rp "Домен сайта-заглушки на этом сервере (Enter — без сайта, чистый L4): " SITE_DOMAIN
    SITE_DOMAIN="${SITE_DOMAIN:-}"
    CERT_MODE="${CERT_MODE:-letsencrypt}"

    if [[ -n "$SITE_DOMAIN" ]]; then
        local norm_pair
        norm_pair=$(normalize_domain "$SITE_DOMAIN") || die "Некорректный домен (IDN): '${SITE_DOMAIN}'"
        SITE_DOMAIN="${norm_pair%%$'\t'*}"
        SITE_DOMAIN_DISPLAY="${norm_pair#*$'\t'}"
        is_valid_domain "$SITE_DOMAIN" || die "Некорректный домен: '${SITE_DOMAIN}'"
        local dom_ips
        dom_ips=$(getent ahostsv4 "$SITE_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
        local dns_ip="${PUBLIC_IP:-${LISTEN_IP:-$LOCAL_IP}}"
        if [[ -n "$dns_ip" ]] && ! grep -qw "$dns_ip" <<< "$dom_ips"; then
            warn "DNS ${SITE_DOMAIN_DISPLAY} (${SITE_DOMAIN}) указывает на [${dom_ips:-пусто}], а IP этого входа — ${dns_ip}."
            warn "Let's Encrypt HTTP-01 требует, чтобы A-запись домена вела на ${dns_ip} (без прокси Cloudflare)."
            if [[ -t 0 ]]; then
                local dns_choice=""
                read -rp "Выберите: 1) Всё равно пробовать Let's Encrypt  2) Самоподписанный TLS (для теста)  3) Выйти [2]: " dns_choice
                dns_choice="${dns_choice:-2}"
                case "$dns_choice" in
                    1) CERT_MODE="letsencrypt" ;;
                    2) CERT_MODE="selfsigned" ;;
                    *) die "Отменено. Обновите DNS A-запись и запустите скрипт снова." ;;
                esac
            else
                CERT_MODE="selfsigned"
            fi
        fi

        if [[ "$CERT_MODE" == "letsencrypt" ]]; then
            [[ "${LE_EMAIL+x}" == "x" ]] || read -rp "Email для Let's Encrypt (Enter — без email): " LE_EMAIL
            LE_EMAIL="${LE_EMAIL:-}"
            [[ -z "$LE_EMAIL" ]] || is_valid_email "$LE_EMAIL" || die "Некорректный email: '${LE_EMAIL}'"
        else
            LE_EMAIL=""
        fi

        SNI_MODE="${SNI_MODE:-}"
        [[ -n "$SNI_MODE" ]] || {
            echo "Режим фильтрации SNI на порту ${LISTEN_PORT} (защита от чужих/случайных SNI):"
            echo "  1) Умный стелс (legacy): SNI-less (77.88.8.1) + указанные VPN-SNI -> EU; чужие/случайные SNI -> сайт RU"
            echo "  2) Строгий whitelist [рекомендуется, макс. стелс]: ТОЛЬКО указанные VPN-SNI -> EU; голый IP и чужие SNI -> сайт RU"
            echo "  3) Прозрачный: только ${SITE_DOMAIN} -> сайт RU, всё остальное -> EU"
            read -rp "Режим SNI [2]: " SNI_MODE
            SNI_MODE="${SNI_MODE:-2}"
        }
        [[ "$SNI_MODE" =~ ^[123]$ ]] || die "Некорректный режим SNI: '${SNI_MODE}' (выберите 1, 2 или 3)"

        VPN_SNIS="${VPN_SNIS:-}"
        if [[ "$SNI_MODE" == "1" || "$SNI_MODE" == "2" ]]; then
            if [[ -z "$VPN_SNIS" && -t 0 ]]; then
                local sni_hint="Enter — только SNI-less 77.88.8.1; можно .domain.tld для поддоменов"
                [[ "$SNI_MODE" == "2" ]] && sni_hint="обязательно, не-CDN TLSv1.3 домены с EU-ноды, напр.: sni1.example.ru sni2.example.ru"
                read -rp "Домены SNI для VPN через пробел или запятую (${sni_hint}): " VPN_SNIS
            fi
            VPN_SNIS="${VPN_SNIS//,/ }"
            if [[ "$SNI_MODE" == "2" && -z "${VPN_SNIS// /}" ]]; then
                die "В строгом режиме (2) нужно указать хотя бы один домен SNI для VPN."
            fi
            local s s_lc site_lc
            site_lc=$(printf '%s' "$SITE_DOMAIN" | tr '[:upper:]' '[:lower:]')
            for s in $VPN_SNIS; do
                is_valid_sni_pattern "$s" || die "Некорректный VPN SNI домен: '${s}'"
                s_lc=$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')
                [[ "${s_lc#.}" != "$site_lc" ]] || die "VPN SNI '${s}' не может совпадать с доменом сайта-заглушки '${SITE_DOMAIN}'."
            done
        fi
    else
        SNI_MODE="3"
        VPN_SNIS=""
    fi

    local default_ssh
    default_ssh=$(detect_ssh_port)
    [[ -n "${SSH_PORT:-}" ]] || { read -rp "Порт SSH этого сервера (для firewall) [${default_ssh}]: " SSH_PORT; SSH_PORT="${SSH_PORT:-$default_ssh}"; }
    is_valid_port "$SSH_PORT" || die "Некорректный SSH-порт: '${SSH_PORT}'"

    local tcp_plan="${EU_TARGET_HOST}:${EU_TCP_PORT}"
    (( ${#EU_IPS[@]} > 1 )) && tcp_plan="eu_tcp_pool (${#EU_IPS[@]} IP, порт ${EU_TCP_PORT})"
    info "План: :${LISTEN_PORT}/tcp -> ${tcp_plan} | UDP: $([[ "$EU_UDP_PORT" != "0" ]] && echo "${EU_TARGET_HOST}:${EU_UDP_PORT}" || echo off) | Сайт: ${SITE_DOMAIN_DISPLAY:-${SITE_DOMAIN:-off}} (${CERT_MODE}, SNI-режим=${SNI_MODE}) | SSH: ${SSH_PORT}"
}

configure_sysctl() {
    info "Применяю сетевой тюнинг ядра (BBR, fq, 16M буферы, mtu_probing=1, mptcp=0), виртуализация: $(systemd-detect-virt 2>/dev/null || echo unknown)..."
    rm -f /etc/sysctl.d/99-relay.conf
    modprobe tcp_bbr >/dev/null 2>&1 || true
    # nf_conntrack нужно загрузить ДО sysctl, иначе net.netfilter.nf_conntrack_max молча не применится
    modprobe nf_conntrack >/dev/null 2>&1 || true
    mkdir -p /etc/modules-load.d
    printf 'tcp_bbr\nnf_conntrack\n' > /etc/modules-load.d/relay-net.conf
    # fq вместо cake: cake заметно грузит CPU (особенно на 1 vCPU), для BBR-релея достаточно fq
    local default_qdisc="fq"
    cat <<EOF > /etc/sysctl.d/99-network.conf
net.core.default_qdisc = ${default_qdisc}
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 262144 16777216
net.ipv4.tcp_wmem = 4096 262144 16777216
net.ipv4.tcp_mtu_probing = 1
net.mptcp.enabled = 0
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10240 65535
net.netfilter.nf_conntrack_max = 262144
EOF
    sysctl --system >/dev/null 2>&1 || true
    local def_if
    def_if=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
    if [[ -n "$def_if" && "$def_if" != "lo" ]] && command -v tc >/dev/null 2>&1; then
        tc qdisc replace dev "$def_if" root "$default_qdisc" >/dev/null 2>&1 || tc qdisc replace dev "$def_if" root fq >/dev/null 2>&1 || true
    fi
    ok "Sysctl: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?'), qdisc=$(tc qdisc show dev "${def_if:-eth0}" 2>/dev/null | awk 'NR==1{print $2}' || echo '?'), rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || echo '?'), mptcp=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo 'n/a')"
    local ip_item ping_flag
    for ip_item in "${EU_IPS[@]}"; do
        ping_flag="-4"; is_valid_ipv6 "$ip_item" && ping_flag="-6"
        ping "$ping_flag" -c 2 -W 2 "$ip_item" >/dev/null 2>&1 && ok "ICMP (${ping_flag}) до ${ip_item}: OK" || warn "ICMP (${ping_flag}) до ${ip_item} не ответил (продолжаю)."
    done
}

install_packages() {
    info "Устанавливаю nginx, libnginx-mod-stream, certbot, openssl, iptables-persistent..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq nginx libnginx-mod-stream certbot openssl curl ca-certificates iptables iptables-persistent
    ok "Пакеты установлены."
}

apply_fw_rules() {
    local bin="$1"
    ensure_rule() { "$bin" -C "$@" 2>/dev/null || "$bin" -A "$@"; }
    ensure_rule INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ensure_rule INPUT -i lo -j ACCEPT
    [[ "$bin" == "ip6tables" ]] && ensure_rule INPUT -p ipv6-icmp -j ACCEPT
    ensure_rule INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT
    ensure_rule INPUT -p tcp --dport "$LISTEN_PORT" -j ACCEPT
    [[ -n "$SITE_DOMAIN" ]] && ensure_rule INPUT -p tcp --dport 80 -j ACCEPT
    [[ "$EU_UDP_PORT" != "0" ]] && ensure_rule INPUT -p udp --dport "$EU_UDP_PORT" -j ACCEPT
}

configure_firewall() {
    info "Настраиваю IPv4/IPv6 firewall (SSH ${SSH_PORT}, ${LISTEN_PORT}/tcp${SITE_DOMAIN:+, 80/tcp}$([[ "$EU_UDP_PORT" != "0" ]] && echo ", ${EU_UDP_PORT}/udp"))..."
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

configure_nginx_base() {
    for svc in apache2 caddy haproxy; do
        systemctl is-active --quiet "$svc" 2>/dev/null && systemctl disable --now "$svc" || true
    done
    mkdir -p /etc/systemd/system/nginx.service.d /root/nginx-backup
    cp -a /etc/nginx/sites-enabled /etc/nginx/conf.d /root/nginx-backup/ 2>/dev/null || true
    rm -f /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf /etc/nginx/stream-enabled.conf

    printf '[Service]\nLimitNOFILE=65536\n' > /etc/systemd/system/nginx.service.d/limits.conf
    systemctl daemon-reload

    sed -i '/stream-enabled\.conf/d' /etc/nginx/nginx.conf
    grep -qE 'worker_connections\s+[0-9]{1,3};' /etc/nginx/nginx.conf && sed -i -E 's/worker_connections\s+[0-9]+;/worker_connections 8192;/' /etc/nginx/nginx.conf || true
    grep -q 'worker_rlimit_nofile' /etc/nginx/nginx.conf || sed -i '1i worker_rlimit_nofile 65536;' /etc/nginx/nginx.conf
    grep -q 'include /etc/nginx/stream.conf;' /etc/nginx/nginx.conf || printf '\ninclude /etc/nginx/stream.conf;\n' >> /etc/nginx/nginx.conf
}

write_site_files() {
    mkdir -p "${SITE_ROOT:-/var/www/site}" /var/www/certbot
    local script_dir deploy_helper
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    deploy_helper="${script_dir}/ops/deploy_speedtest_site.sh"
    export SITE_DOMAIN SITE_DOMAIN_DISPLAY="${SITE_DOMAIN_DISPLAY:-$SITE_DOMAIN}"
    if [[ -f "$deploy_helper" ]]; then
        bash "$deploy_helper" "${SITE_ROOT:-/var/www/site}"
    else
        local tmp_deploy
        tmp_deploy=$(mktemp)
        curl -fsSL --max-time 15 "${SITE_REPO_RAW:-https://raw.githubusercontent.com/BarqDev1/remn_node/main}/ops/deploy_speedtest_site.sh" -o "$tmp_deploy"
        bash "$tmp_deploy" "${SITE_ROOT:-/var/www/site}"
        rm -f "$tmp_deploy"
    fi
}

write_http80_server() {
    local v6="" l4="80"
    [[ -z "${LISTEN_IP:-}" && -f /proc/net/if_inet6 ]] && v6=$'\n    listen [::]:80 default_server;'
    [[ -z "${LISTEN_IP:-}" ]] || l4="${LISTEN_IP}:80"
    cat <<EOF
server {
    listen ${l4} default_server;${v6}
    server_name ${SITE_DOMAIN};
    server_tokens off;
    access_log off;
    location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; default_type text/plain; }
    location / { return 301 https://${SITE_DOMAIN}\$request_uri; }
}
EOF
}

obtain_certificate() {
    if [[ "$CERT_MODE" == "selfsigned" ]]; then
        warn "Выпускаю тестовый самоподписанный сертификат для ${SITE_DOMAIN} (НЕ используйте в продакшене!)."
        mkdir -p "/etc/ssl/site/${SITE_DOMAIN}"
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 365 \
            -subj "/CN=${SITE_DOMAIN}" -addext "subjectAltName=DNS:${SITE_DOMAIN}" \
            -keyout "/etc/ssl/site/${SITE_DOMAIN}/privkey.pem" \
            -out "/etc/ssl/site/${SITE_DOMAIN}/fullchain.pem" >/dev/null 2>&1
        CERT_FULLCHAIN="/etc/ssl/site/${SITE_DOMAIN}/fullchain.pem"
        CERT_PRIVKEY="/etc/ssl/site/${SITE_DOMAIN}/privkey.pem"
        ok "Тестовый сертификат создан."
        return
    fi

    info "Настраиваю HTTP :80 и выпускаю Let's Encrypt для ${SITE_DOMAIN}..."
    : > /etc/nginx/stream.conf
    write_http80_server > "/etc/nginx/sites-enabled/${SITE_CONF_NAME:-site}.conf"
    nginx -t && systemctl enable --now nginx && systemctl reload nginx

    local email_args=(--register-unsafely-without-email)
    [[ -n "$LE_EMAIL" ]] && email_args=(--email "$LE_EMAIL")
    certbot certonly --webroot -w /var/www/certbot -d "$SITE_DOMAIN" \
        --non-interactive --agree-tos "${email_args[@]}" --keep-until-expiring

    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/usr/bin/env bash\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    CERT_FULLCHAIN="/etc/letsencrypt/live/${SITE_DOMAIN}/fullchain.pem"
    CERT_PRIVKEY="/etc/letsencrypt/live/${SITE_DOMAIN}/privkey.pem"
    ok "Сертификат Let's Encrypt готов."
}

render_stream_body() {
    local upstream_block="" udp_block="" map_block="" preread="" tcp_target="" connect_opts=""
    local tag="${PROFILE_TAG:+_${PROFILE_TAG}}" listen_host="${LISTEN_IP:-0.0.0.0}"
    if (( ${#EU_TARGET_HOSTS[@]} > 1 )); then
        local srv_lines="" h
        for h in "${EU_TARGET_HOSTS[@]}"; do
            srv_lines+="        server ${h}:${EU_TCP_PORT} max_fails=2 fail_timeout=15s;"$'\n'
        done
        upstream_block=$'    upstream eu_tcp_pool'"${tag}"$' {\n'"${srv_lines}"$'    }\n\n'
        tcp_target="eu_tcp_pool${tag}"
        connect_opts=$'        proxy_connect_timeout 3s;\n        proxy_next_upstream on;\n        proxy_next_upstream_tries 2;\n        proxy_next_upstream_timeout 6s;'
    else
        tcp_target="${EU_TARGET_HOST}:${EU_TCP_PORT}"
        connect_opts='        proxy_connect_timeout 5s;'
    fi
    local target="${tcp_target}"
    if [[ "$EU_UDP_PORT" != "0" ]]; then
        udp_block=$'\n    server {\n        listen '"${listen_host}:${EU_UDP_PORT}"$' udp;\n        proxy_pass '"${EU_TARGET_HOST}:${EU_UDP_PORT}"$';\n        proxy_timeout 60s;\n        proxy_buffer_size 128k;\n    }'
    fi
    if [[ -n "$SITE_DOMAIN" ]]; then
        local map_entries="" s
        if [[ "${SNI_MODE:-2}" == "3" ]]; then
            map_entries="        ${SITE_DOMAIN} 127.0.0.1:${SITE_BACKEND_PORT:-8443};"$'\n'"        default ${tcp_target};"
        else
            [[ "${SNI_MODE:-2}" == "1" ]] && map_entries+="        \"\" ${tcp_target};"$'\n'
            for s in ${VPN_SNIS:-}; do
                map_entries+="        ${s} ${tcp_target};"$'\n'
            done
            map_entries+="        default 127.0.0.1:${SITE_BACKEND_PORT:-8443};"
        fi
        map_block=$'    map $ssl_preread_server_name $backend_upstream'"${tag}"$' {\n        hostnames;\n'"${map_entries}"$'\n    }\n'
        preread=$'        ssl_preread on;\n'
        target="\$backend_upstream${tag}"
    fi
    cat <<EOF
${upstream_block}${map_block}    server {
        listen ${listen_host}:${LISTEN_PORT};
${preread}        proxy_pass ${target};
${connect_opts}
        proxy_timeout 300s;
        proxy_buffer_size 128k;
        proxy_socket_keepalive on;
        tcp_nodelay on;
    }${udp_block}
EOF
}

render_stream_conf() {
    printf 'stream {\n    access_log off;\n    error_log /var/log/nginx/error.log crit;\n'
    render_stream_body
    printf '}\n'
}

print_security_headers() {
    local indent="${1:-    }"
    cat <<EOF
${indent}add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
${indent}add_header X-Content-Type-Options "nosniff" always;
${indent}add_header X-Frame-Options "DENY" always;
${indent}add_header Referrer-Policy "strict-origin-when-cross-origin" always;
${indent}add_header Permissions-Policy "camera=(), geolocation=(), microphone=(), focus-without-user-activation=()" always;
${indent}add_header Cross-Origin-Opener-Policy "same-origin" always;
${indent}add_header Cross-Origin-Resource-Policy "same-origin" always;
${indent}add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; font-src 'self'; manifest-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'" always;
EOF
}

derive_node_id() {
    local dom="${1:-}"
    if [[ -z "$dom" || "$dom" == "xn--e1aaxpdcc.xn--p1ai" ]]; then
        printf 'RU-MSK-01\n'
        return
    fi
    local first="${dom%%.*}"
    if [[ "$first" == xn--* ]]; then
        printf 'RU-NODE\n'
        return
    fi
    local clean
    clean=$(printf '%s' "$first" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9-')
    clean="${clean:0:12}"
    printf '%s\n' "${clean:-RU-NODE}"
}

render_site_nginx_conf() {
    write_http80_server
    local sec_hdrs sec_hdrs_loc node_id
    sec_hdrs=$(print_security_headers "    ")
    sec_hdrs_loc=$(print_security_headers "        ")
    node_id=$(derive_node_id "${SITE_DOMAIN:-}")
    cat <<EOF

server {
    listen 127.0.0.1:${SITE_BACKEND_PORT:-8443} ssl http2 default_server;
    server_name ${SITE_DOMAIN};

    ssl_certificate ${CERT_FULLCHAIN};
    ssl_certificate_key ${CERT_PRIVKEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_ecdh_curve auto;
    ssl_prefer_server_ciphers off;
    ssl_session_tickets off;
    ssl_session_cache shared:WEB_SSL:10m;
    ssl_session_timeout 1d;

    server_tokens off;
    access_log off;
    error_log /var/log/nginx/error.log crit;
    gzip on;
    gzip_vary on;
    gzip_min_length 256;
    gzip_types text/plain text/css text/javascript application/javascript application/json application/xml image/svg+xml;
    etag on;

${sec_hdrs}

    root ${SITE_ROOT:-/var/www/site};
    index index.html;
    error_page 404 /404.html;
    location = /404.html { internal; }
    location = /api/ping {
        default_type application/json;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
${sec_hdrs_loc}
        return 200 '{"ok":true,"ts":"\$msec"}';
    }
    location = /api/meta {
        default_type application/json;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
${sec_hdrs_loc}
        return 200 '{"ok":true,"tls":"\$ssl_protocol","cipher":"\$ssl_cipher","http":"\$server_protocol","node":"${node_id}","ts":"\$msec"}';
    }
    location = /api/upload {
        client_max_body_size 16m;
        client_body_buffer_size 256k;
        proxy_request_buffering on;
        proxy_pass http://127.0.0.1:8445/sink;
    }
    location ^~ /speed/ {
        gzip off;
        etag off;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
${sec_hdrs_loc}
    }
    location ~* \.(css|js|svg|ico|webmanifest)$ {
        expires 7d;
        add_header Cache-Control "public, max-age=604800" always;
${sec_hdrs_loc}
    }
    location ~ /\. { return 404; }
    location ~* \.(env|git|sql|bak|log|ini|conf)$ { return 404; }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
    [[ -z "${SKIP_SINK:-}" ]] || return 0
    cat <<EOF

server {
    listen 127.0.0.1:8445;
    access_log off;
    error_log /var/log/nginx/error.log crit;
    location = /sink { return 204; }
}
EOF
}

write_final_nginx_configs() {
    if [[ -n "$SITE_DOMAIN" ]]; then
        render_site_nginx_conf > /etc/nginx/sites-enabled/site.conf
    else
        rm -f /etc/nginx/sites-enabled/site.conf
    fi

    render_stream_conf > /etc/nginx/stream.conf
}

resolve_port_conflict() {
    local stopped_realm=0
    if systemctl is-active --quiet realm 2>/dev/null; then
        info "Останавливаю старый realm.service для переключения на Nginx stream..."
        systemctl stop realm
        stopped_realm=1
    fi

    if port_in_use_tcp "$LISTEN_PORT"; then
        local holder
        holder=$(ss -tlpn 2>/dev/null | grep -E "[:.]${LISTEN_PORT}\s" | head -n 1 || true)
        if ! grep -q 'nginx' <<< "$holder"; then
            warn "Порт ${LISTEN_PORT}/tcp сейчас занят: ${holder}"
            if [[ -t 0 && -z "${PROFILE_MODE:-}" ]]; then
                local pchoice=""
                echo "  1) Остановить контейнер remnanode (если занят им) и занять порт ${LISTEN_PORT}"
                echo "  2) Оставить текущий сервис работать и перенести RU-релей на другой порт (например 8444)"
                read -rp "Выберите действие [1]: " pchoice
                pchoice="${pchoice:-1}"
                if [[ "$pchoice" == "2" ]]; then
                    read -rp "Новый входной TCP-порт для Nginx [8444]: " LISTEN_PORT
                    LISTEN_PORT="${LISTEN_PORT:-8444}"
                    is_valid_port "$LISTEN_PORT" || die "Некорректный порт: '${LISTEN_PORT}'"
                    configure_firewall
                    write_final_nginx_configs
                elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'remnanode'; then
                    docker update --restart=no remnanode >/dev/null 2>&1 || true
                    docker stop remnanode >/dev/null 2>&1 || true
                    ok "remnanode остановлен, порт ${LISTEN_PORT} освобождён."
                fi
            fi
        fi
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
    ok "Nginx stream запущен на порту ${LISTEN_PORT}/tcp."
}

verify_result() {
    info "Открытые порты:"
    ss -tulnp | grep -E ":(80|${LISTEN_PORT}|${EU_UDP_PORT})\b" || true
    if [[ -n "$SITE_DOMAIN" ]]; then
        local curl_flags=(-fsS --max-time 5 --resolve "${SITE_DOMAIN}:${LISTEN_PORT}:${LISTEN_IP:-127.0.0.1}")
        [[ "$CERT_MODE" == "selfsigned" ]] && curl_flags+=(-k)
        local path code ok_cnt=0 env_code ul_code=""
        local paths=(/ /network.html /methodology.html /faq.html /about.html /privacy.html /css/tokens-base.css /css/speedtest.css /js/theme-init.js /js/nav-ui.js /js/speedtest-engine.js /js/history-store.js /js/speedtest-ui.js /js/network-diag.js /api/ping /api/meta /speed/payload-1m.bin /favicon.svg /robots.txt /sitemap.xml)
        for path in "${paths[@]}"; do
            code=$(curl "${curl_flags[@]}" -o /dev/null -w "%{http_code}" "https://${SITE_DOMAIN}:${LISTEN_PORT}${path}" || echo "FAIL")
            [[ "$code" == "200" ]] && ok_cnt=$((ok_cnt + 1)) || warn "GET ${path} -> ${code}"
        done
        local env_flags=(-sS --max-time 5 --resolve "${SITE_DOMAIN}:${LISTEN_PORT}:${LISTEN_IP:-127.0.0.1}")
        [[ "$CERT_MODE" == "selfsigned" ]] && env_flags+=(-k)
        env_code=$(curl "${env_flags[@]}" -o /dev/null -w "%{http_code}" "https://${SITE_DOMAIN}:${LISTEN_PORT}/.env" || echo "FAIL")
        ul_code=$(curl "${env_flags[@]}" -X POST -d "probe" -o /dev/null -w "%{http_code}" "https://${SITE_DOMAIN}:${LISTEN_PORT}/api/upload" || echo "FAIL")
        if [[ "$ok_cnt" -eq "${#paths[@]}" && "$env_code" == "404" && "$ul_code" == "204" ]]; then
            ok "Сайт https://${SITE_DOMAIN_DISPLAY:-$SITE_DOMAIN}:${LISTEN_PORT}/ прошёл проверку (${ok_cnt}/${#paths[@]} HTTP 200, /.env -> 404, /api/upload -> ${ul_code})"
        else
            warn "Проверка сайта: ${ok_cnt}/${#paths[@]} OK, /.env -> ${env_code}, /api/upload -> ${ul_code}"
        fi
        if [[ "${SNI_MODE:-2}" == "1" || "${SNI_MODE:-2}" == "2" ]]; then
            if echo | openssl s_client -connect "${LISTEN_IP:-127.0.0.1}:${LISTEN_PORT}" -servername "random-probe.invalid" 2>/dev/null | grep -qE "CN\s*=\s*${SITE_DOMAIN}"; then
                ok "Фильтр чужих SNI (random-probe.invalid): остаётся локально на RU (${SITE_DOMAIN}), EU не светится."
            else
                warn "Проверка чужого SNI не подтвердила локальный сертификат ${SITE_DOMAIN}."
            fi
        fi
        if [[ "${SNI_MODE:-2}" == "2" ]]; then
            if echo | openssl s_client -connect "${LISTEN_IP:-127.0.0.1}:${LISTEN_PORT}" -noservername 2>/dev/null | grep -qE "CN\s*=\s*${SITE_DOMAIN}"; then
                ok "Скан голого IP (без SNI / RealiTLScanner): остаётся локально на RU (${SITE_DOMAIN}), EU полностью скрыт."
            else
                warn "Проверка голого IP (без SNI) не подтвердила локальный сертификат ${SITE_DOMAIN}."
            fi
        fi
    fi
    echo "============================================================"
    local tcp_summary="${EU_TARGET_HOST}:${EU_TCP_PORT}"
    (( ${#EU_IPS[@]} > 1 )) && tcp_summary="eu_tcp_pool (${#EU_IPS[@]} IP -> :${EU_TCP_PORT})"
    ok "RU-релей готов: TCP :${LISTEN_PORT} -> ${tcp_summary}$([[ "$EU_UDP_PORT" != "0" ]] && echo " | UDP :${EU_UDP_PORT} -> ${EU_TARGET_HOST}:${EU_UDP_PORT}" || echo " | UDP: выкл")"
    (( ${#EU_IPS[@]} > 1 )) && echo "  TCP пул: ${EU_IPS[*]}"
    [[ -n "$SITE_DOMAIN" ]] && echo "  Сайт-заглушка: https://${SITE_DOMAIN_DISPLAY:-$SITE_DOMAIN}$([[ "$LISTEN_PORT" != "443" ]] && echo ":${LISTEN_PORT}")/ (7 страниц, Speedtest, TLS 1.2/1.3, HTTP/2, ${CERT_MODE})"
    [[ -n "$SITE_DOMAIN" ]] && echo "  SNI-режим: ${SNI_MODE} | Разрешённые VPN SNI -> EU: $([[ "${SNI_MODE:-2}" == "2" ]] && echo "${VPN_SNIS}" || ([[ "${SNI_MODE:-2}" == "1" ]] && echo "\"\" (77.88.8.1) ${VPN_SNIS}" || echo "default (все кроме ${SITE_DOMAIN})"))"
    echo "  Remnawave Host: Address=${SITE_DOMAIN:-<IP_RU_VPS>}, Port=${LISTEN_PORT}"
    echo "============================================================"
}

# ---------------------------------------------------------------------------
# Мульти-профильный режим: несколько входов (RU IP:порт) -> свои EU-направления.
# Запуск: sudo bash setup_ru_relay.sh --profiles /root/relay-profiles.conf
# Формат файла (INI, см. relay-profiles.example.conf): секция [имя] + параметры
#   listen_ip (обяз.), eu_ip (обяз.), public_ip, listen_port, eu_tcp_port,
#   eu_udp_port, site_domain, sni_mode, vpn_snis, cert_mode, le_email
# ---------------------------------------------------------------------------
PROFILE_KEYS=" listen_ip public_ip listen_port eu_ip eu_tcp_port eu_udp_port site_domain sni_mode vpn_snis cert_mode le_email "
PROFILE_STATE_VARS=(LISTEN_IP PUBLIC_IP LISTEN_PORT EU_IP EU_IPS EU_TARGET_HOST EU_TARGET_HOSTS EU_TCP_PORT EU_UDP_PORT
    SITE_DOMAIN SITE_DOMAIN_DISPLAY CERT_MODE LE_EMAIL SNI_MODE VPN_SNIS SITE_ROOT SITE_CONF_NAME SITE_BACKEND_PORT
    PROFILE_TAG CERT_FULLCHAIN CERT_PRIVKEY SKIP_SINK)

parse_profiles_file() {
    local file="$1" line key val cur="" lineno=0
    [[ -r "$file" ]] || die "Файл профилей не найден или не читается: ${file}"
    declare -gA PROF=()
    PROFILE_NAMES=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] || continue
        if [[ "$line" =~ ^\[([a-z0-9][a-z0-9_-]{0,15})\]$ ]]; then
            cur="${BASH_REMATCH[1]}"
            [[ -z "${PROF[${cur}.__seen]:-}" ]] || die "Профили: строка ${lineno}: секция [${cur}] повторяется."
            PROF[${cur}.__seen]=1
            PROFILE_NAMES+=("$cur")
            continue
        fi
        [[ -n "$cur" ]] || die "Профили: строка ${lineno}: параметр вне секции [имя]."
        [[ "$line" =~ ^([a-z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || die "Профили: строка ${lineno}: ожидалось key=value."
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        val="${val#\"}"; val="${val%\"}"
        [[ "$PROFILE_KEYS" == *" ${key} "* ]] || die "Профили: строка ${lineno}: неизвестный параметр '${key}'."
        PROF[${cur}.${key}]="$val"
    done < "$file"
    (( ${#PROFILE_NAMES[@]} >= 1 )) || die "В файле профилей нет ни одной секции [имя]."
}

profile_get() { printf '%s' "${PROF[${1}.${2}]:-${3:-}}"; }

load_profile() {
    local n="$1" idx="$2"
    PROFILE_TAG="${n//-/_}"
    LISTEN_IP="$(profile_get "$n" listen_ip)"
    PUBLIC_IP="$(profile_get "$n" public_ip)"
    LISTEN_PORT="$(profile_get "$n" listen_port 443)"
    EU_IP="$(profile_get "$n" eu_ip)"
    EU_TCP_PORT="$(profile_get "$n" eu_tcp_port 443)"
    EU_UDP_PORT="$(profile_get "$n" eu_udp_port 0)"
    SITE_DOMAIN="$(profile_get "$n" site_domain)"
    SNI_MODE="$(profile_get "$n" sni_mode 2)"
    VPN_SNIS="$(profile_get "$n" vpn_snis)"
    CERT_MODE="$(profile_get "$n" cert_mode letsencrypt)"
    LE_EMAIL="$(profile_get "$n" le_email)"
    SITE_DOMAIN_DISPLAY=""; CERT_FULLCHAIN=""; CERT_PRIVKEY=""
    SITE_ROOT="/var/www/site-${PROFILE_TAG}"
    SITE_CONF_NAME="profile_${PROFILE_TAG}"
    SITE_BACKEND_PORT=$((18443 + idx))
    SKIP_SINK=1
    [[ -n "$LISTEN_IP" ]] || die "Профиль [${n}]: listen_ip обязателен."
    [[ -n "$EU_IP" ]] || die "Профиль [${n}]: eu_ip обязателен."
    [[ "$CERT_MODE" == "letsencrypt" || "$CERT_MODE" == "selfsigned" ]] || die "Профиль [${n}]: cert_mode должен быть letsencrypt или selfsigned."
    info "--- Профиль [${n}] ---"
    prompt_inputs
}

save_profile_state() {
    PROFILE_STATE[$1]=$(declare -p "${PROFILE_STATE_VARS[@]}" | sed 's/^declare -/declare -g -/')
}

write_sink_conf() {
    cat > /etc/nginx/sites-enabled/00_sink.conf <<'EOF'
server {
    listen 127.0.0.1:8445;
    access_log off;
    error_log /var/log/nginx/error.log crit;
    location = /sink { return 204; }
}
EOF
}

main_profiles() {
    [[ "${EUID}" -eq 0 ]] || die "Запустите скрипт от root (sudo bash $0)."
    parse_profiles_file "$PROFILES_FILE"
    PROFILE_MODE=1
    SSH_PORT="${SSH_PORT:-$(detect_ssh_port)}"
    declare -gA PROFILE_STATE=()
    local name idx=0 bind seen_bind=" " seen_dom=" " stream_all=""
    info "Профилей: ${#PROFILE_NAMES[@]} (${PROFILE_NAMES[*]})"
    for name in "${PROFILE_NAMES[@]}"; do
        load_profile "$name" "$idx"
        bind="${LISTEN_IP}:${LISTEN_PORT}"
        [[ "$seen_bind" != *" ${bind} "* ]] || die "Профиль [${name}]: вход ${bind} уже занят другим профилем."
        seen_bind+="${bind} "
        if [[ -n "$SITE_DOMAIN" ]]; then
            [[ "$seen_dom" != *" ${SITE_DOMAIN} "* ]] || die "Профиль [${name}]: домен ${SITE_DOMAIN} уже используется другим профилем."
            seen_dom+="${SITE_DOMAIN} "
        fi
        save_profile_state "$name"
        idx=$((idx + 1))
    done

    configure_sysctl
    install_packages
    configure_nginx_base
    for name in "${PROFILE_NAMES[@]}"; do
        eval "${PROFILE_STATE[$name]}"
        info "=== Профиль [${name}]: ${LISTEN_IP}:${LISTEN_PORT} -> ${EU_IPS[*]}:${EU_TCP_PORT} ==="
        configure_firewall
        if [[ -n "$SITE_DOMAIN" ]]; then
            write_site_files
            obtain_certificate
            render_site_nginx_conf > "/etc/nginx/sites-enabled/${SITE_CONF_NAME}.conf"
        fi
        stream_all+="    # профиль ${name}"$'\n'"$(render_stream_body)"$'\n'
        save_profile_state "$name"
    done
    write_sink_conf
    { printf 'stream {\n    access_log off;\n    error_log /var/log/nginx/error.log crit;\n'; printf '%s' "$stream_all"; printf '}\n'; } > /etc/nginx/stream.conf
    resolve_port_conflict
    for name in "${PROFILE_NAMES[@]}"; do
        eval "${PROFILE_STATE[$name]}"
        info "=== Проверка профиля [${name}] ==="
        verify_result
    done
    ok "Все профили применены: ${PROFILE_NAMES[*]}"
}

main() {
    [[ "${EUID}" -eq 0 ]] || die "Запустите скрипт от root (sudo bash $0)."
    prompt_inputs
    configure_sysctl
    install_packages
    configure_firewall
    configure_nginx_base
    if [[ -n "$SITE_DOMAIN" ]]; then
        write_site_files
        obtain_certificate
    fi
    write_final_nginx_configs
    resolve_port_conflict
    verify_result
}
if [[ -z "${SETUP_RU_RELAY_SOURCE_ONLY:-}" ]]; then
    if [[ "${1:-}" == "--profiles" ]]; then
        [[ -n "${2:-}" ]] || die "Использование: --profiles <файл>"
        PROFILES_FILE="$2"
    fi
    if [[ -n "${PROFILES_FILE:-}" ]]; then
        main_profiles
    else
        main "$@"
    fi
fi
