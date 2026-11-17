#!/usr/bin/env python3
"""Local, read-only web server for the starter kit dashboard. Standard library only.

It serves exactly these things and nothing else:
  /               the viewer page (index.html from the kit)
  /data/<name>    the JSON files and live.log that export.py writes for one repository
  /report.html    cm's own HTML report
It answers GET and HEAD only and has no endpoint that runs commands.

A background thread re-runs the exporter when cm's local state or the git state
of the repository changes, so the page follows `cm find`, `cm fix` and commits
without any extra step.
"""

import argparse
import http.server
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

DATA_NAME = re.compile(r"^[a-z]+\.(json|log)$")
TYPES = {".html": "text/html; charset=utf-8", ".json": "application/json; charset=utf-8",
         ".log": "text/plain; charset=utf-8"}


def make_handler(page, dash_dir):
    data_dir = dash_dir / "data"

    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "CodeMenderStarterDashboard"

        def resolve(self):
            path = self.path.split("?", 1)[0].split("#", 1)[0]
            if path in ("/", "/index.html"):
                return page
            if path == "/report.html":
                return dash_dir / "report.html"
            if path.startswith("/data/") and DATA_NAME.match(path[len("/data/"):]):
                return data_dir / path[len("/data/"):]
            return None

        def respond(self, with_body):
            target = self.resolve()
            try:
                body = target.read_bytes() if target is not None else None
            except OSError:
                body = None
            if body is None:
                self.send_error(404, "Not found")
                return
            self.send_response(200)
            self.send_header("Content-Type", TYPES.get(target.suffix, "application/octet-stream"))
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            if with_body:
                self.wfile.write(body)

        def do_GET(self):
            self.respond(True)

        def do_HEAD(self):
            self.respond(False)

        def log_message(self, fmt, *args):
            # The page polls every two seconds; don't log each request.
            pass

    return Handler


def fingerprint(repo, cm_home):
    """A cheap summary of everything the dashboard shows: cm's state and the git state."""
    parts = []
    for name in ("state.db", "state.db-wal"):
        try:
            st = (cm_home / name).stat()
            parts.append(f"{name}:{st.st_mtime_ns}:{st.st_size}")
        except OSError:
            parts.append(f"{name}:-")
    for args in (["rev-parse", "HEAD"], ["status", "--porcelain"]):
        try:
            p = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True, timeout=20)
            parts.append(p.stdout)
        except (OSError, subprocess.TimeoutExpired):
            parts.append("?")
    return "\n".join(parts)


def refresher(repo, exporter, cm_home):
    """Re-exports when something changed and has then been quiet for a couple of seconds."""
    exported = fingerprint(repo, cm_home)
    seen, seen_at = exported, time.time()
    while True:
        time.sleep(2)
        current = fingerprint(repo, cm_home)
        now = time.time()
        if current != seen:
            seen, seen_at = current, now
            continue
        if current != exported and now - seen_at >= 2:
            try:
                subprocess.run([sys.executable, str(exporter), "refresh", "--quiet"], cwd=repo,
                               timeout=300, stdin=subprocess.DEVNULL)
            except (OSError, subprocess.TimeoutExpired):
                pass
            # The export itself can touch cm's state; take the fingerprint after it.
            exported = seen = fingerprint(repo, cm_home)
            seen_at = time.time()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", required=True, help="repository whose data is shown")
    ap.add_argument("--dash-dir", required=True, help="<git dir>/codemender/dashboard of that repository")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--bind", default="127.0.0.1")
    args = ap.parse_args()

    kit_dashboard = Path(__file__).resolve().parent
    repo = Path(args.repo).resolve()
    dash_dir = Path(args.dash_dir).resolve()
    cm_home = Path(os.environ.get("CM_HOME") or (Path.home() / ".codemender"))

    threading.Thread(target=refresher, args=(repo, kit_dashboard / "export.py", cm_home),
                     daemon=True).start()
    handler = make_handler(kit_dashboard / "index.html", dash_dir)
    with http.server.ThreadingHTTPServer((args.bind, args.port), handler) as httpd:
        print(f"serving the dashboard for {repo} on {args.bind}:{args.port}", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
