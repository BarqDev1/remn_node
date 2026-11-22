#!/usr/bin/env bash
# EU Node single-port :443 Nginx stream SNI multiplexer for pure external REALITY inbounds.
# Routes SNI on 0.0.0.0:443 -> local Xray loopback inbounds (127.0.0.1:10443/10444/10445)
# with zero self-steal HTTP server and zero local TLS certificates.
# Usage: sudo bash setup_eu_stream443.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Запустите скрипт от root (sudo bash $0)."

is_valid_domain() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]]; }

prompt_inputs() {
    echo "============================================================"
    echo "  Настройка EU single-port :443 Nginx stream (чистый REALITY)"
    echo "============================================================"
    SNI_TCP="${SNI_TCP:-}"
    SNI_XHTTP="${SNI_XHTTP:-}"
    SNI_BACKUP="${SNI_BACKUP:-}"
    if [[ -z "$SNI_TCP" && -t 0 ]]; then
        read -rp "SNI #1 (VLESS-TCP-REALITY -> 127.0.0.1:10443) [kernel.org]: " SNI_TCP
    fi
    SNI_TCP="${SNI_TCP:-kernel.org}"
    if [[ -z "$SNI_XHTTP" && -t 0 ]]; then
        read -rp "SNI #2 (VLESS-XHTTP-REALITY -> 127.0.0.1:10444) [www.ubuntu.com]: " SNI_XHTTP
    fi
    SNI_XHTTP="${SNI_XHTTP:-www.ubuntu.com}"
    if [[ -z "$SNI_BACKUP" && -t 0 ]]; then
        read -rp "SNI #3 (VLESS-REALITY-BACKUP -> 127.0.0.1:10445) [www.debian.org]: " SNI_BACKUP
    fi
    SNI_BACKUP="${SNI_BACKUP:-www.debian.org}"

    for d in "$SNI_TCP" "$SNI_XHTTP" "$SNI_BACKUP"; do
        is_valid_domain "$d" || die "Некорректный домен: '${d}'"
    done
    [[ "$SNI_TCP" != "$SNI_XHTTP" && "$SNI_TCP" != "$SNI_BACKUP" && "$SNI_XHTTP" != "$SNI_BACKUP" ]] || die "Все 3 SNI должны быть разными."

    info "Проверка целей TLSv1.3 + ALPN h2 напрямую с этой ноды:"
    for d in "$SNI_TCP" "$SNI_XHTTP" "$SNI_BACKUP"; do
        local out
        out=$(echo | openssl s_client -connect "${d}:443" -servername "$d" -alpn h2 -tls1_3 2>/dev/null | grep -E "Protocol|ALPN protocol" | tr '\n' ' ' || true)
        if grep -q "TLSv1.3" <<< "$out" && grep -q "h2" <<< "$out"; then
            ok "  ${d}:443 -> TLSv1.3 + h2 OK"
        else
            warn "  ${d}:443 -> не подтвердилось TLSv1.3+h2 (${out:-нет ответа})"
        fi
    done
}

install_and_tune() {
    info "Устанавливаю nginx + libnginx-mod-stream (если ещё не установлены)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq nginx libnginx-mod-stream openssl

    info "Применяю сетевой тюнинг ядра (BBR, mptcp=0, ecn=0)..."
    cat <<'EOF' > /etc/sysctl.d/99-network.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.mptcp.enabled = 0
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fastopen = 0
net.ipv4.tcp_slow_start_after_idle = 0
net.core.somaxconn = 4096
net.ipv4.ip_local_port_range = 10240 65535
net.netfilter.nf_conntrack_max = 262144
EOF
    sysctl --system >/dev/null 2>&1 || true

    mkdir -p /etc/systemd/system/nginx.service.d /root/nginx-selfsteal-backup
    cp -a /etc/nginx/sites-enabled /etc/nginx/conf.d /root/nginx-selfsteal-backup/ 2>/dev/null || true
    rm -f /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.conf /etc/nginx/stream-enabled.conf

    printf '[Service]\nLimitNOFILE=65535\n' > /etc/systemd/system/nginx.service.d/limits.conf
    systemctl daemon-reload
    sed -i '/stream-enabled\.conf/d' /etc/nginx/nginx.conf
    grep -qE 'worker_connections\s+[0-9]{1,3};' /etc/nginx/nginx.conf && sed -i -E 's/worker_connections\s+[0-9]+;/worker_connections 8192;/' /etc/nginx/nginx.conf || true
    grep -q 'worker_rlimit_nofile' /etc/nginx/nginx.conf || sed -i '1i worker_rlimit_nofile 65535;' /etc/nginx/nginx.conf
    grep -q 'include /etc/nginx/stream.conf;' /etc/nginx/nginx.conf || printf '\ninclude /etc/nginx/stream.conf;\n' >> /etc/nginx/nginx.conf
}

write_stream_config() {
    cat <<EOF > /etc/nginx/stream.conf
stream {
    access_log off;
    error_log /var/log/nginx/error.log crit;
    map \$ssl_preread_server_name \$xray_backend {
        ${SNI_TCP}     127.0.0.1:10443;
        ${SNI_XHTTP}   127.0.0.1:10444;
        ${SNI_BACKUP}  127.0.0.1:10445;
        default        127.0.0.1:10443;
    }
    server {
        listen 0.0.0.0:443;
        ssl_preread on;
        proxy_pass \$xray_backend;
        proxy_connect_timeout 5s;
        proxy_timeout 300s;
        proxy_socket_keepalive on;
        tcp_nodelay on;
    }
}
EOF
}

activate_and_verify() {
    if ss -tlpn 2>/dev/null | grep -qE '[:.]443\s' && ! ss -tlpn 2>/dev/null | grep -E '[:.]443\s' | grep -q 'nginx'; then
        warn "Порт 443/tcp сейчас занят Xray/remnanode! Сначала примените в панели Remnawave новый профиль (инбаунды на 127.0.0.1:10443..10445), затем перезапустите Nginx:"
        echo "  systemctl restart nginx"
        nginx -t
        exit 0
    fi

    nginx -t
    systemctl enable nginx
    systemctl restart nginx
    systemctl is-active --quiet nginx || die "Nginx не запустился (journalctl -u nginx -n 30)."
    ok "Nginx stream запущен на 0.0.0.0:443 (self-steal удалён, бэкап в /root/nginx-selfsteal-backup)."

    info "Открытые порты (443 и локальные Xray 10443-10445):"
    ss -tulnp | grep -E ':(443|10443|10444|10445)\b' || true

    info "Проверка REALITY fallback через локальный :443:"
    for d in "$SNI_TCP" "$SNI_XHTTP" "$SNI_BACKUP"; do
        if echo | openssl s_client -connect 127.0.0.1:443 -servername "$d" -alpn h2 -tls1_3 2>/dev/null | grep -q "TLSv1.3"; then
            ok "  SNI ${d} -> 127.0.0.1:443 (TLSv1.3 OK)"
        else
            warn "  SNI ${d} -> инбаунд Xray ещё не слушает 127.0.0.1:10443-10445 (примените профиль в Remnawave)."
        fi
    done
    echo "============================================================"
    ok "EU single-port :443 готов:"
    echo "  ${SNI_TCP}    -> 127.0.0.1:10443 (VLESS-TCP-REALITY)"
    echo "  ${SNI_XHTTP}  -> 127.0.0.1:10444 (VLESS-XHTTP-REALITY)"
    echo "  ${SNI_BACKUP} -> 127.0.0.1:10445 (VLESS-REALITY-BACKUP)"
    echo "============================================================"
}

main() {
    prompt_inputs
    install_and_tune
    write_stream_config
    activate_and_verify
}
main "$@"
