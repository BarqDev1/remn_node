#!/usr/bin/env bash
# Interactive RU Relay (L4 Cascade + stealth multi-page HTTPS site) setup.
# Usage: sudo bash setup_ru_relay.sh
# Non-interactive examples:
#   sudo EU_IP=203.0.113.10 SITE_DOMAIN=site.example.com SITE_THEME=1 bash setup_ru_relay.sh
#   sudo EU_IP="2001:db8::1 2001:db8::2 2001:db8::3" SITE_DOMAIN=site.example.com SNI_MODE=2 VPN_SNIS="www.kernel.org www.debian.org" bash setup_ru_relay.sh
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

    local ip_item
    for ip_item in "${EU_IPS[@]}"; do
        if [[ -n "$LOCAL_IP" && "$ip_item" == "$LOCAL_IP" && "$LISTEN_PORT" == "$EU_TCP_PORT" ]]; then
            die "Петля трафика: ${LOCAL_IP}:${LISTEN_PORT} -> ${ip_item}:${EU_TCP_PORT}. Укажите IP европейской ноды или другой порт."
        fi
    done

    [[ -n "${EU_UDP_PORT:-}" ]] || { read -rp "UDP-порт для проброса (0 — выкл [макс. стелс], 2443 — Hysteria2) [0]: " EU_UDP_PORT; EU_UDP_PORT="${EU_UDP_PORT:-0}"; }
    [[ "$EU_UDP_PORT" == "0" ]] || is_valid_port "$EU_UDP_PORT" || die "Некорректный UDP-порт: '${EU_UDP_PORT}'"

    [[ "${SITE_DOMAIN+x}" == "x" ]] || read -rp "Домен сайта-заглушки на этом сервере (Enter — без сайта, чистый L4): " SITE_DOMAIN
    SITE_DOMAIN="${SITE_DOMAIN:-}"
    SITE_THEME="${SITE_THEME:-}"
    CERT_MODE="${CERT_MODE:-letsencrypt}"

    if [[ -n "$SITE_DOMAIN" ]]; then
        is_valid_domain "$SITE_DOMAIN" || die "Некорректный домен: '${SITE_DOMAIN}'"
        local dom_ips
        dom_ips=$(getent ahostsv4 "$SITE_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
        if [[ -n "$LOCAL_IP" ]] && ! grep -qw "$LOCAL_IP" <<< "$dom_ips"; then
            warn "DNS ${SITE_DOMAIN} указывает на [${dom_ips:-пусто}], а IP этого сервера — ${LOCAL_IP}."
            warn "Let's Encrypt HTTP-01 требует, чтобы A-запись домена вела на ${LOCAL_IP} (без прокси Cloudflare)."
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

        [[ -n "$SITE_THEME" ]] || {
            echo "Выберите тематику многостраничного сайта-заглушки:"
            echo "  1) АвтоТехСервис (диагностика, ТО и автозапчасти по VIN)"
            echo "  2) ТехноСистемы (ИТ-инфраструктура, сети, серверы, СКУД)"
            echo "  3) ТрансЛогистик (сборные грузы, склад класса B+, доставка)"
            read -rp "Номер темы [1]: " SITE_THEME
            SITE_THEME="${SITE_THEME:-1}"
        }
        [[ "$SITE_THEME" =~ ^[123]$ ]] || die "Некорректная тема: '${SITE_THEME}' (выберите 1, 2 или 3)"

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
            echo "  1) Умный стелс [рекомендуется]: SNI-less (77.88.8.1) + указанные VPN-SNI -> EU; чужие/случайные SNI -> сайт RU"
            echo "  2) Строгий whitelist (макс. стелс): ТОЛЬКО указанные VPN-SNI -> EU; голый IP и чужие SNI -> сайт RU"
            echo "  3) Прозрачный: только ${SITE_DOMAIN} -> сайт RU, всё остальное -> EU"
            read -rp "Режим SNI [1]: " SNI_MODE
            SNI_MODE="${SNI_MODE:-1}"
        }
        [[ "$SNI_MODE" =~ ^[123]$ ]] || die "Некорректный режим SNI: '${SNI_MODE}' (выберите 1, 2 или 3)"

        VPN_SNIS="${VPN_SNIS:-}"
        if [[ "$SNI_MODE" == "1" || "$SNI_MODE" == "2" ]]; then
            if [[ -z "$VPN_SNIS" && -t 0 ]]; then
                local sni_hint="Enter — только SNI-less 77.88.8.1; можно .domain.tld для поддоменов"
                [[ "$SNI_MODE" == "2" ]] && sni_hint="обязательно, напр.: www.kernel.org www.debian.org"
                read -rp "Домены SNI для VPN через пробел или запятую (${sni_hint}): " VPN_SNIS
            fi
            VPN_SNIS="${VPN_SNIS//,/ }"
            if [[ "$SNI_MODE" == "2" && -z "${VPN_SNIS// /}" ]]; then
                die "В строгом режиме (2) нужно указать хотя бы один домен SNI для VPN."
            fi
            local s s_lc
            for s in $VPN_SNIS; do
                is_valid_sni_pattern "$s" || die "Некорректный VPN SNI домен: '${s}'"
                s_lc="${s,,}"
                [[ "${s_lc#.}" != "${SITE_DOMAIN,,}" ]] || die "VPN SNI '${s}' не может совпадать с доменом сайта-заглушки '${SITE_DOMAIN}'."
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
    info "План: :${LISTEN_PORT}/tcp -> ${tcp_plan} | UDP: $([[ "$EU_UDP_PORT" != "0" ]] && echo "${EU_TARGET_HOST}:${EU_UDP_PORT}" || echo off) | Сайт: ${SITE_DOMAIN:-off} (${CERT_MODE}, SNI-режим=${SNI_MODE}) | SSH: ${SSH_PORT}"
}

configure_sysctl() {
    info "Применяю сетевой тюнинг ядра (BBR, cake/fq, 16M буферы, mtu_probing=1, mptcp=0), виртуализация: $(systemd-detect-virt 2>/dev/null || echo unknown)..."
    rm -f /etc/sysctl.d/99-relay.conf
    modprobe tcp_bbr >/dev/null 2>&1 || true
    modprobe sch_cake >/dev/null 2>&1 || true
    cat <<'EOF' > /etc/sysctl.d/99-network.conf
net.core.default_qdisc = fq
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
net.ipv4.ip_local_port_range = 10240 65535
net.netfilter.nf_conntrack_max = 262144
EOF
    sysctl --system >/dev/null 2>&1 || true
    local def_if
    def_if=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
    if [[ -n "$def_if" && "$def_if" != "lo" ]] && command -v tc >/dev/null 2>&1; then
        tc qdisc replace dev "$def_if" root cake >/dev/null 2>&1 || tc qdisc replace dev "$def_if" root fq >/dev/null 2>&1 || true
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

    printf '[Service]\nLimitNOFILE=65535\n' > /etc/systemd/system/nginx.service.d/limits.conf
    systemctl daemon-reload

    sed -i '/stream-enabled\.conf/d' /etc/nginx/nginx.conf
    grep -qE 'worker_connections\s+[0-9]{1,3};' /etc/nginx/nginx.conf && sed -i -E 's/worker_connections\s+[0-9]+;/worker_connections 8192;/' /etc/nginx/nginx.conf || true
    grep -q 'worker_rlimit_nofile' /etc/nginx/nginx.conf || sed -i '1i worker_rlimit_nofile 65535;' /etc/nginx/nginx.conf
    grep -q 'include /etc/nginx/stream.conf;' /etc/nginx/nginx.conf || printf '\ninclude /etc/nginx/stream.conf;\n' >> /etc/nginx/nginx.conf
}

load_theme() {
    case "${SITE_THEME:-1}" in
        2)
            BRAND="ТехноСистемы"; LEGAL="ООО «ТехноСистемы Интеграция»"; INN="7724418920"
            ACCENT="#0f172a"; ACCENT2="#0284c7"; TAGLINE="Корпоративные сети, серверы и инженерная безопасность"
            DESC="Проектирование и сопровождение ИТ-инфраструктуры, корпоративных ЛВС, серверных и систем контроля доступа."
            HERO_H="Надёжная ИТ-инфраструктура для офисов и производств"
            HERO_P="Проектируем и обслуживаем корпоративные сети, серверные комнаты, IP-телефонию и системы видеонаблюдения с прозрачным SLA."
            STAT1="9+ лет"; STAT1_L="на рынке системной интеграции"; STAT2="320+"; STAT2_L="реализованных проектов"
            STAT3="99.9%"; STAT3_L="доступность узлов по SLA"; STAT4="12 мес."; STAT4_L="гарантия на монтаж и работы"
            S1_H="Корпоративные сети и СКС"; S1_P="Проектирование кабельных систем, настройка коммутаторов, Wi-Fi и резервирование каналов."; S1_PR="от 18 000 ₽"
            S2_H="Администрирование серверов"; S2_P="Мониторинг 24/7, резервное копирование, виртуализация и регламентное обновление систем."; S2_PR="от 25 000 ₽/мес"
            S3_H="Видеонаблюдение и СКУД"; S3_P="Монтаж и пусконаладка систем контроля доступа, биометрии и охранного телевидения."; S3_PR="от 32 000 ₽"
            S4_H="Аудит ИТ-инфраструктуры"; S4_P="Инвентаризация оборудования, проверка отказоустойчивости и план модернизации узлов."; S4_PR="от 15 000 ₽"
            S5_H="Корпоративная IP-телефония"; S5_P="Внедрение АТС, маршрутизация вызовов, запись разговоров и интеграция с CRM."; S5_PR="от 14 000 ₽"
            S6_H="Аварийный выезд инженеров"; S6_P="Оперативная диагностика сбоев, замена комплектующих и восстановление сервисов."; S6_PR="от 4 500 ₽"
            ABOUT_P="Компания «ТехноСистемы» работает с 2017 года и специализируется на построении отказоустойчивой корпоративной ИТ-инфраструктуры. Наши сертифицированные инженеры сопровождают офисные, складские и производственные площадки в Москве и области."
            FAQ1_Q="Работаете ли вы по договору с НДС?"; FAQ1_A="Да, предоставляем полный пакет закрывающих документов через ЭДО, работаем по договорам подряда и абонентского SLA."
            FAQ2_Q="Как быстро возможен выезд на аудит объекта?"; FAQ2_A="Инженер выезжает на площадку в течение 1–2 рабочих дней после согласования технического задания."
            FAQ3_Q="Даёте ли гарантию на смонтированные сети?"; FAQ3_A="На все монтажные и пусконаладочные работы действует гарантия 12 месяцев, на оборудование — гарантия производителя."
            SCHED="Пн–Пт 09:00–19:00"; ADDR="115201, г. Москва, ул. Промышленная, д. 14, офис 308"; PHONE="+7 (495) 012-44-18"
            ;;
        3)
            BRAND="ТрансЛогистик"; LEGAL="ООО «ТрансЛогистик Групп»"; INN="5036184290"
            ACCENT="#14532d"; ACCENT2="#16a34a"; TAGLINE="Сборные грузоперевозки и ответственное хранение"
            DESC="Региональные перевозки паллетных и сборных грузов, склад класса B+, кросс-докинг и экспедирование по РФ."
            HERO_H="Региональная логистика и складское хранение класса B+"
            HERO_P="Доставка сборных и паллетных партий по Центральному округу и регионам РФ, кросс-докинг, маркировка и полный документооборот."
            STAT1="10+ лет"; STAT1_L="в коммерческой логистике"; STAT2="14 000 м²"; STAT2_L="складских площадей B+"
            STAT3="98.7%"; STAT3_L="доставок точно в срок"; STAT4="24/7"; STAT4_L="охрана и учёт WMS"
            S1_H="Сборные грузоперевозки"; S1_P="Регулярные межтерминальные рейсы от 1 паллеты с фиксированным графиком отправок."; S1_PR="от 3 200 ₽"
            S2_H="Ответственное хранение"; S2_P="Стеллажное и напольное хранение, учёт по партиям и срокам годности в системе WMS."; S2_PR="от 38 ₽/паллет"
            S3_H="Кросс-докинг и сортировка"; S3_P="Быстрая перегрузка без длительного хранения, паллетирование и стикеровка под требования сетей."; S3_PR="от 450 ₽/паллет"
            S4_H="Выделенный транспорт"; S4_P="Подача фургонов и тентованных машин 1.5–20 тонн под прямые коммерческие рейсы."; S4_PR="от 9 500 ₽"
            S5_H="Доставка в торговые сети"; S5_P="Соблюдение временных окон приёмки, возврат подписанных накладных и контроль паллет."; S5_PR="от 5 400 ₽"
            S6_H="Страхование и экспедирование"; S6_P="Оформление страхового полиса на полную стоимость партии и мониторинг маршрута."; S6_PR="от 0.15%"
            ABOUT_P="«ТрансЛогистик» объединяет собственный автопарк мало- и среднетоннажного транспорта и современный распределительный комплекс в Подмосковье. Автоматизированный учёт WMS позволяет клиентам получать ежедневные отчёты по остаткам и отгрузкам."
            FAQ1_Q="Какой минимальный объём принимается на хранение?"; FAQ1_A="Принимаем партии от 5 европаллет с помесячной или посуточной тарификацией."
            FAQ2_Q="Возможна ли доставка в распределительные центры сетей?"; FAQ2_A="Да, мы соблюдаем требования к маркировке, высоте паллет и временным окнам приёмки."
            FAQ3_Q="Как оформляются закрывающие документы?"; FAQ3_A="Передаём УПД, транспортные накладные и акты через системы ЭДО (Диадок, СБИС) или курьером."
            SCHED="Пн–Сб 08:00–20:00"; ADDR="142116, Московская обл., г. Подольск, Домодедовское ш., д. 22, стр. 3"; PHONE="+7 (495) 018-73-90"
            ;;
        *)
            BRAND="АвтоТехСервис"; LEGAL="ООО «АвтоТехСервис М»"; INN="7726391405"
            ACCENT="#1e293b"; ACCENT2="#2563eb"; TAGLINE="Компьютерная диагностика, ТО и автозапчасти по VIN"
            DESC="Техническое обслуживание, компьютерная диагностика, ремонт ходовой части и подбор автозапчастей по VIN."
            HERO_H="Техническое обслуживание и точный подбор запчастей по VIN"
            HERO_P="Компьютерная диагностика электронных систем, регламентное ТО, ремонт подвески и поставка сертифицированных комплектующих для легковых и коммерческих авто."
            STAT1="8+ лет"; STAT1_L="профильного обслуживания"; STAT2="6 800+"; STAT2_L="выполненных заказ-нарядов"
            STAT3="6 постов"; STAT3_L="подъёмники и стенд сход-развал"; STAT4="12 мес."; STAT4_L="гарантия на работы и детали"
            S1_H="Компьютерная диагностика"; S1_P="Считывание и расшифровка кодов ЭБУ, проверка датчиков, топливной и тормозной систем."; S1_PR="от 1 800 ₽"
            S2_H="Плановое ТО по регламенту"; S2_P="Замена моторного масла, фильтров, свечей, тормозной и охлаждающей жидкостей."; S2_PR="от 4 200 ₽"
            S3_H="Подбор запчастей по VIN"; S3_P="Поиск оригинальных деталей и проверенных аналогов с контролем применимости по каталогам."; S3_PR="бесплатно"
            S4_H="Ремонт ходовой и тормозов"; S4_P="Замена дисков, колодок, рычагов, амортизаторов, ступичных подшипников и рулевых тяг."; S4_PR="от 2 500 ₽"
            S5_H="Замена ремней и цепей ГРМ"; S5_P="Регламентная замена комплектов ГРМ с выставлением фаз специнструментом."; S5_PR="от 8 500 ₽"
            S6_H="Обслуживание автопарков"; S6_P="Корпоративное ТО коммерческого транспорта по договору с безналичной оплатой."; S6_PR="по договору"
            ABOUT_P="Технический центр «АвтоТехСервис» работает с 2017 года. Выполняем регламентное обслуживание и диагностику автомобилей европейских, корейских, японских и отечественных марок с сохранением истории работ в сервисной карте."
            FAQ1_Q="Нужно ли записываться заранее на диагностику и ТО?"; FAQ1_A="Рекомендуем предварительную запись — так мы заранее подготовим пост и зарезервируем необходимые расходники по VIN."
            FAQ2_Q="Можно ли приехать со своими запчастями?"; FAQ2_A="Да, при наличии сертификата соответствия. На выполненные работы предоставляется стандартная гарантия."
            FAQ3_Q="Работаете ли вы с юридическими лицами и автопарками?"; FAQ3_A="Да, заключаем договоры корпоративного обслуживания с предоставлением счетов, актов и заказ-нарядов."
            SCHED="Пн–Сб 09:00–20:00"; ADDR="117519, г. Москва, Варшавское ш., д. 132А, корп. 2"; PHONE="+7 (495) 014-62-35"
            ;;
    esac
}

render_page() {
    local file="$1" title="$2" active="$3" body="$4"
    local c_home="" c_srv="" c_abt="" c_faq="" c_cnt=""
    case "$active" in
        home) c_home=' class="active"' ;; services) c_srv=' class="active"' ;;
        about) c_abt=' class="active"' ;; faq) c_faq=' class="active"' ;; contacts) c_cnt=' class="active"' ;;
    esac
    cat <<EOF > "/var/www/site/${file}"
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${title} — ${BRAND}</title>
  <meta name="description" content="${DESC}">
  <meta name="theme-color" content="${ACCENT}">
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="manifest" href="/site.webmanifest">
  <link rel="stylesheet" href="/style.css">
</head>
<body>
  <header class="site-header">
    <div class="wrap nav-row">
      <a class="brand" href="/"><img src="/favicon.svg" alt="" width="28" height="28"><span>${BRAND}</span></a>
      <button class="nav-toggle" type="button" aria-label="Меню">☰</button>
      <nav class="main-nav">
        <a href="/"${c_home}>Главная</a>
        <a href="/services.html"${c_srv}>Услуги и цены</a>
        <a href="/about.html"${c_abt}>О компании</a>
        <a href="/faq.html"${c_faq}>Вопросы</a>
        <a href="/contacts.html"${c_cnt}>Контакты</a>
      </nav>
    </div>
  </header>
${body}
  <footer class="site-footer">
    <div class="wrap footer-grid">
      <div><strong>${BRAND}</strong><p>${TAGLINE}. ${LEGAL}, ИНН ${INN}.</p></div>
      <div><strong>Разделы</strong><p><a href="/services.html">Услуги и прайс</a> · <a href="/about.html">О компании</a> · <a href="/faq.html">Частые вопросы</a> · <a href="/privacy.html">Политика 152-ФЗ</a></p></div>
      <div><strong>Контакты</strong><p>${ADDR}<br>${SCHED} · <a href="mailto:info@${SITE_DOMAIN}">info@${SITE_DOMAIN}</a></p></div>
    </div>
    <div class="wrap footer-bottom">© <span data-year>2026</span> ${LEGAL}. Все права защищены.</div>
  </footer>
  <script src="/app.js" defer></script>
</body>
</html>
EOF
}

write_site_files() {
    mkdir -p /var/www/site /var/www/certbot
    load_theme

    cat <<EOF > /var/www/site/style.css
:root{--bg:#f8fafc;--card:#ffffff;--ink:#0f172a;--muted:#475569;--line:#e2e8f0;--accent:${ACCENT};--accent2:${ACCENT2}}
*{box-sizing:border-box}html{scroll-behavior:smooth}
body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,sans-serif;background:var(--bg);color:var(--ink);line-height:1.6}
a{color:var(--accent2);text-decoration:none}a:hover{text-decoration:underline}
.wrap{max-width:1080px;margin:0 auto;padding:0 20px}
.site-header{background:var(--accent);color:#fff;position:sticky;top:0;z-index:20;box-shadow:0 1px 0 rgba(255,255,255,.08)}
.nav-row{display:flex;align-items:center;justify-content:space-between;min-height:64px;gap:16px}
.brand{display:flex;align-items:center;gap:10px;color:#fff;font-weight:700;font-size:18px;letter-spacing:.2px}.brand:hover{text-decoration:none}
.main-nav{display:flex;gap:20px;align-items:center}.main-nav a{color:#cbd5e1;font-size:14px;font-weight:500}.main-nav a:hover,.main-nav a.active{color:#fff;text-decoration:none}
.nav-toggle{display:none;background:none;border:1px solid rgba(255,255,255,.25);color:#fff;border-radius:6px;padding:6px 10px;font-size:18px;cursor:pointer}
.hero{background:linear-gradient(135deg,var(--accent) 0%,#0f172a 100%);color:#f8fafc;padding:68px 0 60px}
.hero h1{margin:0 0 14px;font-size:36px;line-height:1.2;max-width:760px}.hero p{margin:0 0 26px;max-width:660px;color:#cbd5e1;font-size:16px}
.actions{display:flex;gap:12px;flex-wrap:wrap}
.btn{display:inline-block;padding:11px 20px;border-radius:8px;font-weight:600;font-size:14px;background:var(--accent2);color:#fff;border:0;cursor:pointer}
.btn:hover{opacity:.92;text-decoration:none}.btn-ghost{background:rgba(255,255,255,.1);color:#fff;border:1px solid rgba(255,255,255,.22)}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:16px;margin-top:34px}
.stat{background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.12);border-radius:10px;padding:16px}
.stat strong{display:block;font-size:22px;color:#fff}.stat span{font-size:13px;color:#cbd5e1}
main{padding:46px 0}h1.page-title{margin:0 0 10px;font-size:30px}h2{margin:0 0 18px;font-size:24px}
.lead{color:var(--muted);max-width:740px;margin:0 0 28px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(290px,1fr));gap:18px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:22px}
.card h3{margin:0 0 8px;font-size:17px}.card p{margin:0;color:var(--muted);font-size:14px}
.price-tag{display:inline-block;margin-top:12px;padding:4px 10px;border-radius:999px;background:#f1f5f9;color:var(--ink);font-size:13px;font-weight:600}
.steps{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:16px;margin-top:18px}
.step{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px}
.step b{display:inline-flex;width:28px;height:28px;align-items:center;justify-content:center;border-radius:50%;background:var(--accent2);color:#fff;font-size:13px;margin-bottom:10px}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}
th,td{padding:13px 16px;border-bottom:1px solid var(--line);text-align:left;font-size:14px}th{background:#f1f5f9;font-weight:600}
details{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px 20px;margin-bottom:12px}
summary{cursor:pointer;font-weight:600;list-style:none}details p{margin:10px 0 0;color:var(--muted);font-size:14px}
.form-box{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:24px;margin-top:24px;max-width:620px}
.field{margin-bottom:14px}.field label{display:block;font-size:13px;font-weight:600;margin-bottom:6px}
.field input,.field textarea{width:100%;padding:10px 12px;border:1px solid #cbd5e1;border-radius:8px;font:inherit;font-size:14px}
.form-msg{margin-top:12px;font-size:14px;color:#15803d;font-weight:500}
.site-footer{border-top:1px solid var(--line);background:#fff;margin-top:40px;padding:34px 0 24px;color:var(--muted);font-size:13px}
.footer-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:22px;margin-bottom:22px}
.footer-grid strong{color:var(--ink);display:block;margin-bottom:6px}.footer-grid p{margin:0}
.footer-bottom{border-top:1px solid var(--line);padding-top:16px;text-align:center;color:#64748b}
@media (max-width:720px){.nav-toggle{display:block}.main-nav{display:none;position:absolute;left:0;right:0;top:64px;background:var(--accent);flex-direction:column;padding:14px 20px;align-items:flex-start}.main-nav.open{display:flex}.hero h1{font-size:28px}}
EOF

    cat <<'EOF' > /var/www/site/app.js
document.addEventListener("DOMContentLoaded", function () {
  var btn = document.querySelector(".nav-toggle");
  var nav = document.querySelector(".main-nav");
  if (btn && nav) {
    btn.addEventListener("click", function () { nav.classList.toggle("open"); });
  }
  var yr = document.querySelector("[data-year]");
  if (yr) { yr.textContent = String(new Date().getFullYear()); }
  var form = document.querySelector("#contact-form");
  if (form) {
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      var msg = document.querySelector("#form-status");
      if (msg) {
        msg.textContent = "Спасибо! Заявка зарегистрирована. Специалист свяжется с вами в рабочее время.";
      }
      form.reset();
    });
  }
});
EOF

    printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 36 36"><rect width="36" height="36" rx="8" fill="%s"/><path d="M9 25L18 9l9 16h-4.5L18 16.5 13.5 25z" fill="#fff"/></svg>\n' "$ACCENT2" > /var/www/site/favicon.svg

    cat <<EOF > /var/www/site/site.webmanifest
{"name":"${BRAND}","short_name":"${BRAND}","start_url":"/","display":"standalone","background_color":"#f8fafc","theme_color":"${ACCENT}","icons":[{"src":"/favicon.svg","sizes":"any","type":"image/svg+xml"}]}
EOF

    render_page "index.html" "Главная" "home" "  <section class=\"hero\"><div class=\"wrap\">
    <h1>${HERO_H}</h1><p>${HERO_P}</p>
    <div class=\"actions\"><a class=\"btn\" href=\"/services.html\">Услуги и цены</a><a class=\"btn btn-ghost\" href=\"/contacts.html\">Оставить заявку</a></div>
    <div class=\"stats\">
      <div class=\"stat\"><strong>${STAT1}</strong><span>${STAT1_L}</span></div>
      <div class=\"stat\"><strong>${STAT2}</strong><span>${STAT2_L}</span></div>
      <div class=\"stat\"><strong>${STAT3}</strong><span>${STAT3_L}</span></div>
      <div class=\"stat\"><strong>${STAT4}</strong><span>${STAT4_L}</span></div>
    </div>
  </div></section>
  <main class=\"wrap\">
    <h2>Основные направления</h2>
    <div class=\"grid\">
      <div class=\"card\"><h3>${S1_H}</h3><p>${S1_P}</p><span class=\"price-tag\">${S1_PR}</span></div>
      <div class=\"card\"><h3>${S2_H}</h3><p>${S2_P}</p><span class=\"price-tag\">${S2_PR}</span></div>
      <div class=\"card\"><h3>${S3_H}</h3><p>${S3_P}</p><span class=\"price-tag\">${S3_PR}</span></div>
      <div class=\"card\"><h3>${S4_H}</h3><p>${S4_P}</p><span class=\"price-tag\">${S4_PR}</span></div>
      <div class=\"card\"><h3>${S5_H}</h3><p>${S5_P}</p><span class=\"price-tag\">${S5_PR}</span></div>
      <div class=\"card\"><h3>${S6_H}</h3><p>${S6_P}</p><span class=\"price-tag\">${S6_PR}</span></div>
    </div>
    <h2 style=\"margin-top:42px\">Порядок работы</h2>
    <div class=\"steps\">
      <div class=\"step\"><b>1</b><h3>Заявка</h3><p>Уточняем задачу, параметры объекта или каталожный запрос.</p></div>
      <div class=\"step\"><b>2</b><h3>Расчёт</h3><p>Согласуем смету, перечень работ и фиксированные сроки.</p></div>
      <div class=\"step\"><b>3</b><h3>Выполнение</h3><p>Проводим работы по утверждённому регламенту качества.</p></div>
      <div class=\"step\"><b>4</b><h3>Приёмка</h3><p>Передаём результат, закрывающие документы и гарантию.</p></div>
    </div>
  </main>"

    render_page "services.html" "Услуги и цены" "services" "  <main class=\"wrap\">
    <h1 class=\"page-title\">Услуги и ориентировочный прайс-лист</h1>
    <p class=\"lead\">${HERO_P} Итоговая стоимость фиксируется до начала работ после первичной оценки.</p>
    <table>
      <thead><tr><th>Направление</th><th>Состав работ</th><th>Стоимость</th></tr></thead>
      <tbody>
        <tr><td><strong>${S1_H}</strong></td><td>${S1_P}</td><td>${S1_PR}</td></tr>
        <tr><td><strong>${S2_H}</strong></td><td>${S2_P}</td><td>${S2_PR}</td></tr>
        <tr><td><strong>${S3_H}</strong></td><td>${S3_P}</td><td>${S3_PR}</td></tr>
        <tr><td><strong>${S4_H}</strong></td><td>${S4_P}</td><td>${S4_PR}</td></tr>
        <tr><td><strong>${S5_H}</strong></td><td>${S5_P}</td><td>${S5_PR}</td></tr>
        <tr><td><strong>${S6_H}</strong></td><td>${S6_P}</td><td>${S6_PR}</td></tr>
      </tbody>
    </table>
    <div class=\"card\" style=\"margin-top:24px\"><h3>Условия для корпоративных клиентов</h3><p>Заключаем договоры с юридическими лицами и ИП, работаем по безналичному расчёту с передачей актов и счетов через ЭДО.</p></div>
  </main>"

    render_page "about.html" "О компании" "about" "  <main class=\"wrap\">
    <h1 class=\"page-title\">О компании ${BRAND}</h1>
    <p class=\"lead\">${TAGLINE}</p>
    <div class=\"card\"><p>${ABOUT_P}</p><p style=\"margin-top:12px\">Мы придерживаемся прозрачного ценообразования, соблюдения технических регламентов и документальной фиксации каждого этапа обслуживания.</p></div>
    <div class=\"grid\" style=\"margin-top:20px\">
      <div class=\"card\"><h3>Реквизиты</h3><p>${LEGAL}<br>ИНН: ${INN}<br>Адрес: ${ADDR}</p></div>
      <div class=\"card\"><h3>Стандарты качества</h3><p>Все специалисты проходят регулярную аттестацию. На выполненные работы и поставляемые комплектующие действует официальная гарантия.</p></div>
    </div>
  </main>"

    render_page "faq.html" "Частые вопросы" "faq" "  <main class=\"wrap\">
    <h1 class=\"page-title\">Часто задаваемые вопросы</h1>
    <p class=\"lead\">Ответы на основные вопросы о сроках, оплате, гарантии и порядке оформления заявок.</p>
    <details open><summary>${FAQ1_Q}</summary><p>${FAQ1_A}</p></details>
    <details><summary>${FAQ2_Q}</summary><p>${FAQ2_A}</p></details>
    <details><summary>${FAQ3_Q}</summary><p>${FAQ3_A}</p></details>
    <details><summary>В какие часы принимаются заявки?</summary><p>Режим работы: ${SCHED}. Запросы на почту info@${SITE_DOMAIN} обрабатываются в ближайший рабочий день.</p></details>
  </main>"

    render_page "contacts.html" "Контакты" "contacts" "  <main class=\"wrap\">
    <h1 class=\"page-title\">Контактная информация</h1>
    <div class=\"grid\">
      <div class=\"card\"><h3>Адрес</h3><p>${ADDR}</p></div>
      <div class=\"card\"><h3>Режим работы</h3><p>${SCHED}</p></div>
      <div class=\"card\"><h3>Связь</h3><p>Тел.: ${PHONE}<br>Email: <a href=\"mailto:info@${SITE_DOMAIN}\">info@${SITE_DOMAIN}</a></p></div>
    </div>
    <div class=\"form-box\">
      <h3>Форма обратной связи</h3>
      <form id=\"contact-form\">
        <div class=\"field\"><label for=\"c-name\">Ваше имя</label><input id=\"c-name\" name=\"name\" required maxlength=\"80\" placeholder=\"Алексей\"></div>
        <div class=\"field\"><label for=\"c-contact\">Телефон или email</label><input id=\"c-contact\" name=\"contact\" required maxlength=\"100\" placeholder=\"+7 (900) 000-00-00\"></div>
        <div class=\"field\"><label for=\"c-note\">Комментарий к запросу</label><textarea id=\"c-note\" name=\"note\" rows=\"3\" maxlength=\"500\" placeholder=\"Кратко опишите задачу\"></textarea></div>
        <button class=\"btn\" type=\"submit\">Отправить заявку</button>
        <div id=\"form-status\" class=\"form-msg\" role=\"status\"></div>
      </form>
    </div>
  </main>"

    render_page "privacy.html" "Политика конфиденциальности" "none" "  <main class=\"wrap\">
    <h1 class=\"page-title\">Политика обработки персональных данных</h1>
    <div class=\"card\">
      <p>Настоящая политика составлена в соответствии с требованиями Федерального закона от 27.07.2006 № 152-ФЗ «О персональных данных» и определяет порядок обработки данных ${LEGAL} (ИНН ${INN}).</p>
      <p style=\"margin-top:12px\">Оператор обрабатывает контактные сведения исключительно для обратной связи по запросам пользователей, заключения и исполнения договоров. Передача сведений третьим лицам без законных оснований не осуществляется.</p>
      <p style=\"margin-top:12px\">По вопросам уточнения или отзыва согласия на обработку данных обращайтесь на <a href=\"mailto:info@${SITE_DOMAIN}\">info@${SITE_DOMAIN}</a>.</p>
    </div>
  </main>"

    render_page "404.html" "Страница не найдена" "none" "  <main class=\"wrap\">
    <h1 class=\"page-title\">404 — Страница не найдена</h1>
    <p class=\"lead\">Запрошенная страница была перемещена или не существует.</p>
    <a class=\"btn\" href=\"/\">Вернуться на главную</a>
  </main>"

    printf 'User-agent: *\nAllow: /\nSitemap: https://%s/sitemap.xml\n' "$SITE_DOMAIN" > /var/www/site/robots.txt
    local today; today=$(date +%Y-%m-%d)
    cat <<EOF > /var/www/site/sitemap.xml
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://${SITE_DOMAIN}/</loc><lastmod>${today}</lastmod><priority>1.0</priority></url>
  <url><loc>https://${SITE_DOMAIN}/services.html</loc><lastmod>${today}</lastmod><priority>0.9</priority></url>
  <url><loc>https://${SITE_DOMAIN}/about.html</loc><lastmod>${today}</lastmod><priority>0.7</priority></url>
  <url><loc>https://${SITE_DOMAIN}/faq.html</loc><lastmod>${today}</lastmod><priority>0.7</priority></url>
  <url><loc>https://${SITE_DOMAIN}/contacts.html</loc><lastmod>${today}</lastmod><priority>0.8</priority></url>
  <url><loc>https://${SITE_DOMAIN}/privacy.html</loc><lastmod>${today}</lastmod><priority>0.3</priority></url>
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
    write_http80_server > /etc/nginx/sites-enabled/site.conf
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

render_stream_conf() {
    local upstream_block="" udp_block="" map_block="" preread="" tcp_target="" connect_opts=""
    if (( ${#EU_TARGET_HOSTS[@]} > 1 )); then
        local srv_lines="" h
        for h in "${EU_TARGET_HOSTS[@]}"; do
            srv_lines+="        server ${h}:${EU_TCP_PORT} max_fails=2 fail_timeout=15s;"$'\n'
        done
        upstream_block=$'    upstream eu_tcp_pool {\n'"${srv_lines}"$'    }\n\n'
        tcp_target="eu_tcp_pool"
        connect_opts=$'        proxy_connect_timeout 3s;\n        proxy_next_upstream on;\n        proxy_next_upstream_tries 2;\n        proxy_next_upstream_timeout 6s;'
    else
        tcp_target="${EU_TARGET_HOST}:${EU_TCP_PORT}"
        connect_opts='        proxy_connect_timeout 5s;'
    fi
    local target="${tcp_target}"
    if [[ "$EU_UDP_PORT" != "0" ]]; then
        udp_block=$'\n    server {\n        listen 0.0.0.0:'"${EU_UDP_PORT}"$' udp;\n        proxy_pass '"${EU_TARGET_HOST}:${EU_UDP_PORT}"$';\n        proxy_timeout 60s;\n        proxy_buffer_size 128k;\n    }'
    fi
    if [[ -n "$SITE_DOMAIN" ]]; then
        local map_entries="" s
        if [[ "${SNI_MODE:-1}" == "3" ]]; then
            map_entries="        ${SITE_DOMAIN} 127.0.0.1:8443;"$'\n'"        default ${tcp_target};"
        else
            [[ "${SNI_MODE:-1}" == "1" ]] && map_entries+="        \"\" ${tcp_target};"$'\n'
            for s in ${VPN_SNIS:-}; do
                map_entries+="        ${s} ${tcp_target};"$'\n'
            done
            map_entries+="        default 127.0.0.1:8443;"
        fi
        map_block=$'    map $ssl_preread_server_name $backend_upstream {\n        hostnames;\n'"${map_entries}"$'\n    }\n'
        preread=$'        ssl_preread on;\n'
        target='$backend_upstream'
    fi
    cat <<EOF
stream {
    access_log off;
    error_log /var/log/nginx/error.log crit;
${upstream_block}${map_block}    server {
        listen 0.0.0.0:${LISTEN_PORT};
${preread}        proxy_pass ${target};
${connect_opts}
        proxy_timeout 300s;
        proxy_buffer_size 128k;
        proxy_socket_keepalive on;
        tcp_nodelay on;
    }${udp_block}
}
EOF
}

write_final_nginx_configs() {
    if [[ -n "$SITE_DOMAIN" ]]; then
        {
            write_http80_server
            cat <<EOF

server {
    listen 127.0.0.1:8443 ssl http2 default_server;
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

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;

    root /var/www/site;
    index index.html;
    error_page 404 /404.html;
    location = /404.html { internal; }
    location ~* \.(css|js|svg|ico|webmanifest)$ { expires 7d; add_header Cache-Control "public, max-age=604800"; }
    location ~ /\. { return 404; }
    location ~* \.(env|git|sql|bak|log|ini|conf)$ { return 404; }
    location / { try_files \$uri \$uri/ =404; }
}
EOF
        } > /etc/nginx/sites-enabled/site.conf
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
            if [[ -t 0 ]]; then
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
        local curl_flags=(-fsS --max-time 5 --resolve "${SITE_DOMAIN}:${LISTEN_PORT}:127.0.0.1")
        [[ "$CERT_MODE" == "selfsigned" ]] && curl_flags+=(-k)
        local path code ok_cnt=0 env_code
        local paths=(/ /services.html /about.html /faq.html /contacts.html /privacy.html /style.css /app.js /favicon.svg /robots.txt /sitemap.xml)
        for path in "${paths[@]}"; do
            code=$(curl "${curl_flags[@]}" -o /dev/null -w "%{http_code}" "https://${SITE_DOMAIN}:${LISTEN_PORT}${path}" || echo "FAIL")
            [[ "$code" == "200" ]] && ok_cnt=$((ok_cnt + 1)) || warn "GET ${path} -> ${code}"
        done
        local env_flags=(-sS --max-time 5 --resolve "${SITE_DOMAIN}:${LISTEN_PORT}:127.0.0.1")
        [[ "$CERT_MODE" == "selfsigned" ]] && env_flags+=(-k)
        env_code=$(curl "${env_flags[@]}" -o /dev/null -w "%{http_code}" "https://${SITE_DOMAIN}:${LISTEN_PORT}/.env" || echo "FAIL")
        if [[ "$ok_cnt" -eq "${#paths[@]}" && "$env_code" == "404" ]]; then
            ok "Сайт https://${SITE_DOMAIN}:${LISTEN_PORT}/ прошёл проверку (${ok_cnt}/${#paths[@]} HTTP 200, /.env -> 404)"
        else
            warn "Проверка сайта: ${ok_cnt}/${#paths[@]} OK, /.env -> ${env_code}"
        fi
        if [[ "${SNI_MODE:-1}" == "1" || "${SNI_MODE:-1}" == "2" ]]; then
            if echo | openssl s_client -connect "127.0.0.1:${LISTEN_PORT}" -servername "random-probe.invalid" 2>/dev/null | grep -qE "CN\s*=\s*${SITE_DOMAIN}"; then
                ok "Фильтр чужих SNI (random-probe.invalid): остаётся локально на RU (${SITE_DOMAIN}), EU не светится."
            else
                warn "Проверка чужого SNI не подтвердила локальный сертификат ${SITE_DOMAIN}."
            fi
        fi
        if [[ "${SNI_MODE:-1}" == "2" ]]; then
            if echo | openssl s_client -connect "127.0.0.1:${LISTEN_PORT}" -noservername 2>/dev/null | grep -qE "CN\s*=\s*${SITE_DOMAIN}"; then
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
    [[ -n "$SITE_DOMAIN" ]] && echo "  Сайт-заглушка: https://${SITE_DOMAIN}$([[ "$LISTEN_PORT" != "443" ]] && echo ":${LISTEN_PORT}")/ (6 страниц, TLS 1.2/1.3, HTTP/2, ${CERT_MODE})"
    [[ -n "$SITE_DOMAIN" ]] && echo "  SNI-режим: ${SNI_MODE} | Разрешённые VPN SNI -> EU: $([[ "${SNI_MODE:-1}" == "2" ]] && echo "${VPN_SNIS}" || ([[ "${SNI_MODE:-1}" == "1" ]] && echo "\"\" (77.88.8.1) ${VPN_SNIS}" || echo "default (все кроме ${SITE_DOMAIN})"))"
    echo "  Remnawave Host: Address=${SITE_DOMAIN:-<IP_RU_VPS>}, Port=${LISTEN_PORT}"
    echo "============================================================"
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
    main "$@"
fi
