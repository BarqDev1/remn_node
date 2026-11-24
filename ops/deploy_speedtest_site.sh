#!/usr/bin/env bash
# Deploy the multi-page speedtest decoy site (ТестНет.рф) into /var/www/site.
set -euo pipefail

TARGET_DIR="${1:-/var/www/site}"
SITE_DOMAIN="${SITE_DOMAIN:-xn--e1aaxpdcc.xn--p1ai}"
SITE_DOMAIN_DISPLAY="${SITE_DOMAIN_DISPLAY:-тестнет.рф}"
SITE_REPO_RAW="${SITE_REPO_RAW:-https://raw.githubusercontent.com/BarqDev1/remn_node/main}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_SITE_DIR=""
if [[ -d "${SCRIPT_DIR}/../site" ]]; then
    LOCAL_SITE_DIR="$(cd "${SCRIPT_DIR}/../site" && pwd)"
elif [[ -d "${SCRIPT_DIR}/site" ]]; then
    LOCAL_SITE_DIR="$(cd "${SCRIPT_DIR}/site" && pwd)"
fi

SITE_FILES=(
    "index.html"
    "network.html"
    "methodology.html"
    "faq.html"
    "about.html"
    "privacy.html"
    "404.html"
    "favicon.svg"
    "site.webmanifest"
    "robots.txt"
    "sitemap.xml"
    "css/tokens-base.css"
    "css/speedtest.css"
    "js/theme-init.js"
    "js/nav-ui.js"
    "js/speedtest-engine.js"
    "js/history-store.js"
    "js/speedtest-ui.js"
    "js/network-diag.js"
)

mkdir -p "${TARGET_DIR}/css" "${TARGET_DIR}/js" "${TARGET_DIR}/speed"

for rel in "${SITE_FILES[@]}"; do
    if [[ -n "$LOCAL_SITE_DIR" && -f "${LOCAL_SITE_DIR}/${rel}" ]]; then
        cp "${LOCAL_SITE_DIR}/${rel}" "${TARGET_DIR}/${rel}"
    else
        curl -fsSL --max-time 15 "${SITE_REPO_RAW}/site/${rel}" -o "${TARGET_DIR}/${rel}"
    fi
done

if [[ "$SITE_DOMAIN" != "xn--e1aaxpdcc.xn--p1ai" ]]; then
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$TARGET_DIR" "$SITE_DOMAIN" "$SITE_DOMAIN_DISPLAY" <<'PYEOF'
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
ascii_dom = sys.argv[2].strip().lower()
disp_dom = sys.argv[3].strip().lower()

is_testnet_family = disp_dom == "тестнет.рф" or disp_dom.endswith(".тестнет.рф")
parts_disp = disp_dom.split(".")
parts_ascii = ascii_dom.split(".")

if is_testnet_family:
    sub = disp_dom[:-len(".тестнет.рф")] if disp_dom.endswith(".тестнет.рф") else "msk1"
    raw_badge = re.sub(r"[^A-Za-zА-Яа-я0-9-]+", "", sub.split(".")[0]).upper()[:10] or "MSK1"
    sub_lc = sub.lower()
    if sub_lc.startswith("spb"):
        city_ix = "Санкт-Петербург · SPB-IX"
    elif sub_lc.startswith(("ekt", "ekb")):
        city_ix = "Екатеринбург · EKT-IX"
    elif sub_lc.startswith("nsk"):
        city_ix = "Новосибирск · NSK-IX"
    else:
        city_ix = "Москва · MSK-IX"
else:
    base_disp = ".".join(parts_disp[-2:]) if len(parts_disp) >= 2 else disp_dom
    base_ascii = ".".join(parts_ascii[-2:]) if len(parts_ascii) >= 2 else ascii_dom
    raw_badge = re.sub(r"[^A-Za-z0-9-]+", "", parts_ascii[0]).upper()[:10] or "NODE"
    city_ix = f"Узел · {base_disp}"

all_files = (
    "robots.txt", "sitemap.xml", "site.webmanifest",
    "index.html", "network.html", "methodology.html",
    "faq.html", "about.html", "privacy.html", "404.html",
)
for name in all_files:
    p = root / name
    if not p.exists():
        continue
    text = p.read_text(encoding="utf-8")
    if name in ("robots.txt", "sitemap.xml"):
        text = text.replace("https://xn--e1aaxpdcc.xn--p1ai", f"https://{ascii_dom}")
    elif is_testnet_family:
        text = text.replace('<span class="logo-badge">MSK-IX</span>', f'<span class="logo-badge">{raw_badge}</span>')
        text = text.replace("Узел: Москва · MSK-IX (тестнет.рф)", f"Узел: {city_ix} ({disp_dom})")
        if name == "network.html":
            text = text.replace("RU-MSK-01 (основной)", f"{raw_badge} ({disp_dom})")
            text = text.replace("<td>Москва · MSK-IX</td>", f"<td>{city_ix}</td>", 1)
    else:
        text = text.replace("xn--e1aaxpdcc.xn--p1ai", base_ascii)
        text = text.replace("тестнет.рф", base_disp).replace("ТестНет.рф", base_disp)
        text = text.replace('<span class="logo-badge">MSK-IX</span>', f'<span class="logo-badge">{raw_badge}</span>')
        text = text.replace(f"Узел: Москва · MSK-IX ({base_disp})", f"Узел: {city_ix} ({disp_dom})")
        if name == "network.html":
            text = text.replace("RU-MSK-01 (основной)", f"{raw_badge} ({disp_dom})")
            text = text.replace("<td>Москва · MSK-IX</td>", f"<td>{city_ix}</td>", 1)
    p.write_text(text, encoding="utf-8")
PYEOF
    fi
fi

# Generate incompressible random payloads so neither gzip nor L4 compression skews throughput
dd if=/dev/urandom of="${TARGET_DIR}/speed/payload-1m.bin" bs=65536 count=16 status=none
dd if=/dev/urandom of="${TARGET_DIR}/speed/payload-4m.bin" bs=65536 count=64 status=none
chmod 0644 "${TARGET_DIR}/speed/payload-1m.bin" "${TARGET_DIR}/speed/payload-4m.bin"
