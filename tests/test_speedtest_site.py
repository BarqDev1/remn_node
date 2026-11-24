"""Verification tests for the ТестНет.рф speedtest site and setup_ru_relay.sh."""

from __future__ import annotations

import json
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "setup_ru_relay.sh"
DEPLOY_HELPER = ROOT / "ops" / "deploy_speedtest_site.sh"
SITE_DIR = ROOT / "site"

sys.path.insert(0, str(ROOT / "scripts"))
import dev_server  # noqa: E402


def _source_bash(cmd_body: str) -> str:
    cmd = f'SETUP_RU_RELAY_SOURCE_ONLY=1 source "{SCRIPT}" && {cmd_body}'
    res = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, check=False)
    assert res.returncode == 0, f"bash failed: {res.stderr}"
    return res.stdout


class SpeedtestSiteTests(unittest.TestCase):
    """Static, shell, and HTTP integration tests for ТестНет.рф."""

    def test_shell_scripts_syntax(self) -> None:
        for path in (SCRIPT, DEPLOY_HELPER):
            self.assertTrue(path.is_file(), f"Missing script: {path}")
            res = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True, check=False)
            self.assertEqual(res.returncode, 0, f"bash -n failed for {path}: {res.stderr}")

    def test_new_and_updated_files_respect_350_line_limit(self) -> None:
        files = [
            DEPLOY_HELPER,
            ROOT / "README.md",
            ROOT / "scripts" / "dev_server.py",
            Path(__file__).resolve(),
            *sorted(SITE_DIR.glob("*.html")),
            *sorted((SITE_DIR / "css").glob("*.css")),
            *sorted((SITE_DIR / "js").glob("*.js")),
        ]
        for path in files:
            lines = len(path.read_text(encoding="utf-8").splitlines())
            self.assertLessEqual(lines, 350, f"{path} exceeds 350 lines ({lines})")

    def test_idn_domain_normalization_for_cyrillic_domain(self) -> None:
        out = _source_bash('normalize_domain "https://тестнет.рф/"').strip()
        ascii_dom, disp_dom = out.split("\t")
        self.assertEqual(ascii_dom, "xn--e1aaxpdcc.xn--p1ai")
        self.assertEqual(disp_dom, "тестнет.рф")

        sub_out = _source_bash('normalize_domain "msk2.тестнет.рф"').strip()
        sub_ascii, sub_disp = sub_out.split("\t")
        self.assertEqual(sub_ascii, "msk2.xn--e1aaxpdcc.xn--p1ai")
        self.assertEqual(sub_disp, "msk2.тестнет.рф")

    def test_subdomain_deployment_preserves_brand_and_updates_node(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            env = os.environ.copy()
            env["SITE_DOMAIN"] = "spb1.xn--e1aaxpdcc.xn--p1ai"
            env["SITE_DOMAIN_DISPLAY"] = "spb1.тестнет.рф"
            res = subprocess.run(
                ["bash", str(DEPLOY_HELPER), tmpdir],
                env=env,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(res.returncode, 0, f"deploy helper failed: {res.stderr}")
            root = Path(tmpdir)
            index_html = (root / "index.html").read_text(encoding="utf-8")
            network_html = (root / "network.html").read_text(encoding="utf-8")
            about_html = (root / "about.html").read_text(encoding="utf-8")
            robots = (root / "robots.txt").read_text(encoding="utf-8")
            sitemap = (root / "sitemap.xml").read_text(encoding="utf-8")

            self.assertIn("<span>ТестНет.рф</span>", index_html)
            self.assertIn('<span class="logo-badge">SPB1</span>', index_html)
            self.assertIn("Узел: Санкт-Петербург · SPB-IX (spb1.тестнет.рф)", index_html)
            self.assertIn("SPB1 (spb1.тестнет.рф)", network_html)
            self.assertIn("<td>Санкт-Петербург · SPB-IX</td>", network_html)
            self.assertIn("mailto:support@xn--e1aaxpdcc.xn--p1ai", about_html)
            self.assertIn("support@тестнет.рф", about_html)
            self.assertIn("https://spb1.xn--e1aaxpdcc.xn--p1ai/sitemap.xml", robots)
            self.assertIn("https://spb1.xn--e1aaxpdcc.xn--p1ai/network.html", sitemap)
            self.assertEqual((root / "speed" / "payload-1m.bin").stat().st_size, 1024 * 1024)
            self.assertEqual((root / "speed" / "payload-4m.bin").stat().st_size, 4 * 1024 * 1024)

        nginx_out = _source_bash(
            'SITE_DOMAIN="msk2.xn--e1aaxpdcc.xn--p1ai" '
            'CERT_FULLCHAIN="/etc/letsencrypt/live/msk2.xn--e1aaxpdcc.xn--p1ai/fullchain.pem" '
            'CERT_PRIVKEY="/etc/letsencrypt/live/msk2.xn--e1aaxpdcc.xn--p1ai/privkey.pem" '
            "render_site_nginx_conf"
        )
        self.assertIn('"node":"MSK2"', nginx_out)

    def test_render_site_nginx_conf_for_speedtest_site(self) -> None:
        out = _source_bash(
            'SITE_DOMAIN="xn--e1aaxpdcc.xn--p1ai" '
            'CERT_FULLCHAIN="/etc/letsencrypt/live/xn--e1aaxpdcc.xn--p1ai/fullchain.pem" '
            'CERT_PRIVKEY="/etc/letsencrypt/live/xn--e1aaxpdcc.xn--p1ai/privkey.pem" '
            "render_site_nginx_conf"
        )
        self.assertIn("server_name xn--e1aaxpdcc.xn--p1ai;", out)
        self.assertIn("location = /api/ping", out)
        self.assertIn("location = /api/meta", out)
        self.assertIn("location = /api/upload", out)
        self.assertIn("location ^~ /speed/", out)
        self.assertIn("gzip off;", out)
        self.assertIn("listen 127.0.0.1:8445;", out)
        self.assertNotIn("$remote_addr", out)
        self.assertIn("Content-Security-Policy", out)
        self.assertNotIn("unsafe-inline", out)
        self.assertNotIn("unsafe-eval", out)

    def test_old_decoy_site_templates_removed(self) -> None:
        src = SCRIPT.read_text(encoding="utf-8")
        for legacy in (
            "load_theme",
            "render_page",
            "SITE_THEME",
            "АвтоТехСервис",
            "ТехноСистемы",
            "ТрансЛогистик",
            "services.html",
            "contacts.html",
        ):
            self.assertNotIn(legacy, src, f"Legacy decoy site artifact still present: {legacy}")

    def test_render_stream_conf_ipv6_pool_and_strict_sni_invariants(self) -> None:
        out = _source_bash(
            'EU_IP="2001:db8:abcd::1 2001:db8:abcd::2" EU_TCP_PORT=443 LISTEN_PORT=443 '
            'EU_UDP_PORT=443 SITE_DOMAIN="xn--e1aaxpdcc.xn--p1ai" SNI_MODE=2 '
            'VPN_SNIS="sni1.example.ru" && parse_eu_ips && render_stream_conf'
        )
        self.assertIn("upstream eu_tcp_pool {", out)
        self.assertIn("sni1.example.ru eu_tcp_pool;", out)
        self.assertIn("default 127.0.0.1:8443;", out)
        self.assertIn("proxy_pass [2001:db8:abcd::1]:443;", out)

    def test_html_and_js_csp_hygiene_and_local_links(self) -> None:
        html_files = sorted(SITE_DIR.glob("*.html"))
        self.assertGreaterEqual(len(html_files), 7)
        for html_path in html_files:
            content = html_path.read_text(encoding="utf-8")
            self.assertIsNone(re.search(r'\sstyle\s*=\s*["\']', content, re.I), f"Inline style in {html_path}")
            self.assertIsNone(re.search(r"<script(?![^>]*\bsrc=)[^>]*>", content, re.I), f"Inline script in {html_path}")
            for ref in re.findall(r'(?:src|href)="(/[^"#?]+)"', content):
                target = SITE_DIR / ("index.html" if ref == "/" else ref.lstrip("/"))
                self.assertTrue(target.exists(), f"Broken local link {ref} in {html_path}")

        for js_path in sorted((SITE_DIR / "js").glob("*.js")):
            src = js_path.read_text(encoding="utf-8")
            for sink in ("innerHTML", "outerHTML", "document.write", "eval("):
                self.assertNotIn(sink, src, f"Forbidden DOM sink {sink} in {js_path}")

    def test_setup_ru_relay_contains_no_hardcoded_secrets_or_prod_domains(self) -> None:
        src = SCRIPT.read_text(encoding="utf-8")
        for forbidden in ("45.92.218.", "153.76.122.", "188.68.55.", "193.233.88.", "141.148.230.", "didoauto.com"):
            self.assertNotIn(forbidden, src)
        self.assertIsNone(re.search(r"privateKey|shortId|BEGIN PRIVATE KEY", src))

    def test_local_dev_server_endpoints_and_headers(self) -> None:
        srv = dev_server.create_server("127.0.0.1", 0)
        port = srv.server_address[1]
        thread = threading.Thread(target=srv.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{port}"
        try:
            for path in (
                "/",
                "/network.html",
                "/methodology.html",
                "/faq.html",
                "/about.html",
                "/privacy.html",
                "/css/tokens-base.css",
                "/css/speedtest.css",
                "/js/theme-init.js",
                "/js/nav-ui.js",
                "/js/speedtest-engine.js",
                "/js/speedtest-ui.js",
                "/js/network-diag.js",
                "/favicon.svg",
                "/robots.txt",
                "/sitemap.xml",
            ):
                with urlopen(f"{base}{path}", timeout=3) as resp:  # noqa: S310
                    self.assertEqual(resp.status, 200, f"GET {path} failed")
                    self.assertIn("default-src 'self'", resp.headers.get("Content-Security-Policy", ""))
                    self.assertEqual(resp.headers.get("X-Frame-Options"), "DENY")

            with urlopen(f"{base}/api/ping", timeout=3) as resp:  # noqa: S310
                data = json.loads(resp.read().decode("utf-8"))
                self.assertTrue(data["ok"])

            with urlopen(f"{base}/api/meta", timeout=3) as resp:  # noqa: S310
                data = json.loads(resp.read().decode("utf-8"))
                self.assertEqual(data["node"], "RU-MSK-01")

            with urlopen(f"{base}/speed/payload-1m.bin", timeout=3) as resp:  # noqa: S310
                self.assertEqual(len(resp.read()), 1024 * 1024)

            req = Request(f"{base}/api/upload", data=b"x" * 4096, method="POST")
            with urlopen(req, timeout=3) as resp:  # noqa: S310
                self.assertEqual(resp.status, 204)

            with self.assertRaises(HTTPError) as ctx:
                urlopen(f"{base}/.env", timeout=3)  # noqa: S310
            self.assertEqual(ctx.exception.code, 404)
            ctx.exception.close()
        finally:
            srv.shutdown()
            srv.server_close()


if __name__ == "__main__":
    unittest.main()
