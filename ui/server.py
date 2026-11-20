#!/usr/bin/env python3
"""
server.py - tiny local web server for the Smart File Organizer UI.

* Uses ONLY the Python standard library (nothing to pip install).
* Listens on 127.0.0.1 only, so it is reachable from your own computer only.
* Runs ../smart_organiser.sh with a fixed list of arguments (no shell),
  and only on folders inside your home folder.

Start:  python3 ui/server.py        then open  http://localhost:8765
"""
import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent                      # the project folder
SCRIPT = ROOT / "smart_organiser.sh"
SETUP = ROOT / "setup_test.sh"
HOME = Path.home().resolve()
REPORT_DIR = HOME / ".sfo" / "reports"
PORT = 8765
LOCK = threading.Lock()                 # one run at a time


def safe_dir(text):
    """Turn the typed folder into a Path, refusing anything risky."""
    path = Path(os.path.expanduser(str(text).strip())).resolve()
    if not path.is_dir():
        raise ValueError("That folder does not exist: %s" % path)
    if path == HOME or HOME not in path.parents:
        raise ValueError("Choose a folder inside your home folder (not the home folder itself).")
    if path == ROOT or ROOT in path.parents or path in ROOT.parents:
        raise ValueError("That folder contains the project's own code. Choose a test folder such as ~/sfo_test.")
    if str(path).startswith(str(HOME / ".sfo")):
        raise ValueError("That folder is used internally by the organiser.")
    return path


def as_int(value, low, high, name):
    try:
        number = int(value)
    except (TypeError, ValueError):
        raise ValueError("%s must be a number." % name)
    if not low <= number <= high:
        raise ValueError("%s must be between %d and %d." % (name, low, high))
    return number


def run_cmd(args):
    proc = subprocess.run(args, capture_output=True, text=True, timeout=600, cwd=str(ROOT))
    return {"ok": proc.returncode == 0, "code": proc.returncode,
            "output": (proc.stdout or "") + (proc.stderr or "")}


def do_run(body):
    action = body.get("action")
    opts = body.get("opts") or {}

    if action == "setup":                         # rebuild ~/sfo_test
        result = run_cmd(["bash", str(SETUP)])
        result["dir"] = str(HOME / "sfo_test")
        return result

    args = ["bash", str(SCRIPT)]
    if action in ("dry", "live"):
        args += ["--dry-run" if action == "dry" else "--organise", str(safe_dir(body.get("dir", "")))]
        if opts.get("recursive"):
            args.append("--recursive")
        if opts.get("date_folders"):
            args.append("--date-folders")
        if opts.get("archive_old"):
            args.append("--archive-old")
        if opts.get("no_rename"):
            args.append("--no-rename")
        args += ["--stale-days", str(as_int(opts.get("stale_days", 90), 0, 36500, "Stale days"))]
        args += ["--large-mb", str(as_int(opts.get("large_mb", 1), 0, 1000000, "Large MB"))]
    elif action == "undo":
        args.append("--undo")
    else:
        raise ValueError("Unknown action.")
    return run_cmd(args)


def do_tree(folder):
    """List a folder (3 levels deep) so the page can show before/after."""
    base = safe_dir(folder)
    entries = []
    for current, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        rel_dir = os.path.relpath(current, base)
        depth = 0 if rel_dir == "." else rel_dir.count(os.sep) + 1
        if depth >= 3:
            dirs[:] = []
        for d in dirs:
            entries.append({"p": os.path.normpath(os.path.join(rel_dir, d)), "d": True})
        for f in sorted(files):
            if f.startswith("."):
                continue
            entries.append({"p": os.path.normpath(os.path.join(rel_dir, f)), "d": False})
        if len(entries) > 600:
            break
    entries.sort(key=lambda e: (e["p"].lower()))
    return {"ok": True, "dir": str(base), "entries": entries[:600]}


def latest_report():
    files = sorted(REPORT_DIR.glob("report_*.md"), key=lambda p: p.stat().st_mtime, reverse=True)
    if not files:
        return {"ok": False, "text": "", "name": ""}
    return {"ok": True, "text": files[0].read_text(errors="replace"), "name": files[0].name}


class Handler(BaseHTTPRequestHandler):
    server_version = "SFO-UI"

    def _send(self, status, payload, ctype="application/json"):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        try:
            if url.path in ("/", "/index.html"):
                self._send(200, (HERE / "index.html").read_bytes(), "text/html")
            elif url.path == "/api/tree":
                self._send(200, do_tree(parse_qs(url.query).get("dir", [""])[0]))
            elif url.path == "/api/report":
                self._send(200, latest_report())
            else:
                self._send(404, {"ok": False, "error": "Not found"})
        except ValueError as err:
            self._send(400, {"ok": False, "error": str(err)})
        except Exception as err:                       # keep the server alive
            self._send(500, {"ok": False, "error": "Server error: %s" % err})

    def do_POST(self):
        if urlparse(self.path).path != "/api/run":
            return self._send(404, {"ok": False, "error": "Not found"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            if not LOCK.acquire(blocking=False):
                raise ValueError("Another run is still in progress. Wait a moment.")
            try:
                self._send(200, do_run(body))
            finally:
                LOCK.release()
        except ValueError as err:
            self._send(400, {"ok": False, "error": str(err)})
        except Exception as err:
            self._send(500, {"ok": False, "error": "Server error: %s" % err})

    def log_message(self, fmt, *args):                 # quieter console
        pass


if __name__ == "__main__":
    if not SCRIPT.exists():
        raise SystemExit("Cannot find %s - run this from the project folder." % SCRIPT)
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("Smart File Organizer UI is running.")
    print("Open this in your browser:  http://localhost:%d" % PORT)
    print("Press Ctrl+C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
