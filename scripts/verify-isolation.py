#!/usr/bin/env python3
"""Check real Chromium cookies/storage persistence using disposable local profiles.

Only visits a loopback HTTP fixture. Does not access any existing browser data.
"""
import html
import http.server
from pathlib import Path
import re
import subprocess
import tempfile
import threading

BROWSER = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        page = b"""<!doctype html><body><script>
        const current = localStorage.getItem('account') || 'empty';
        const cookie = document.cookie || 'empty';
        const next = new URL(location.href).searchParams.get('set');
        if (next) { localStorage.setItem('account', next); document.cookie = 'account=' + next + '; max-age=3600; path=/'; }
        document.body.textContent = 'STORAGE:' + current + '|COOKIE:' + cookie;
        </script></body>"""
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def log_message(self, *args):
        pass


def main():
    assert BROWSER.is_file(), "Google Chrome is required for this integration check"
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    address = f"http://127.0.0.1:{server.server_port}/"
    try:
        with tempfile.TemporaryDirectory(prefix="AI Switcher Isolation ") as temporary:
            def visit(profile, query=""):
                result = subprocess.run([
                    str(BROWSER), f"--user-data-dir={temporary}/{profile}",
                    "--no-first-run", "--no-default-browser-check", "--disable-background-mode",
                    "--headless", "--disable-gpu", "--dump-dom", address + query,
                ], capture_output=True, text=True, timeout=40, check=True)
                match = re.search(r"<body>(.*?)</body>", result.stdout, re.S)
                assert match, f"No fixture response: {result.stdout[:200]}"
                return html.unescape(match.group(1))

            assert visit("A", "?set=account-A") == "STORAGE:empty|COOKIE:empty"
            assert visit("B", "?set=account-B") == "STORAGE:empty|COOKIE:empty"
            assert visit("A") == "STORAGE:account-A|COOKIE:account=account-A"
            assert visit("B") == "STORAGE:account-B|COOKIE:account=account-B"
            print("PASS: cookies and localStorage remain isolated and persist across browser restarts")
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
