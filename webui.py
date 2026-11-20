#!/usr/bin/env python3
"""webui.py - small mobile-friendly web UI for the media queue. Python stdlib only.

Open http://127.0.0.1:8787 in the phone browser (start it with `q ui`).
Safety: listens on 127.0.0.1 only; checks Host/Origin and a custom header on every
change (blocks other web pages and DNS-rebinding). To use it from another device set
WEBUI_HOST=0.0.0.0: then a secret token (data/webui.token) is required.
"""
import json
import os
import re
import secrets
import subprocess
import sys
import time
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

HERE = os.path.dirname(os.path.abspath(__file__))
os.environ.setdefault("QUEUE_DIR", os.path.join(HERE, "data", "queue"))
QUEUE_DIR = os.environ["QUEUE_DIR"]
sys.path.insert(0, HERE)
import qctl as _qctl  # read-only queue access in-process (no subprocess polling = low CPU/battery)

DATA_DIR = os.path.dirname(QUEUE_DIR) if os.path.basename(QUEUE_DIR) == "queue" else QUEUE_DIR
CONFIG = os.environ.get("PIPELINE_CONFIG") or os.path.join(DATA_DIR, "config.conf")
LOG = os.environ.get("PIPELINE_LOG") or os.path.join(HERE, "media_processor_log.txt")
HOST = os.environ.get("WEBUI_HOST", "127.0.0.1")
PORT = int(os.environ.get("WEBUI_PORT", "8787"))
LOOPBACK = HOST in ("127.0.0.1", "localhost", "::1")
PY = sys.executable or "python3"
MAX_BODY = 64 * 1024

# key -> (default, kind, help, extra)
SCHEMA = {
    "NORM_MODE":         ("peak",   "enum", "peak = audio peak set by the percentage below (forced on every file). lufs = loudness target.", ("peak", "lufs")),
    "PEAK_PERCENT":      ("100",    "pct",  "Peak mode: 0 = -9.0 dB, 50 = -4.55 dB, 100 = -0.1 dB (Target dB = -9 + 8.9 x percent/100).", (0.0, 100.0)),
    "TARGET_LUFS":       ("-9",     "num",  "Target loudness (LUFS). Constant gain only, no compression.", (-40.0, 0.0)),
    "TRUE_PEAK_CEILING": ("-1.0",   "num",  "Highest allowed true peak (dBTP). Gain is reduced to stay under it.", (-20.0, 0.0)),
    "VERIFY_DECODE":     ("1",      "enum", "Decode the output audio once to check it (1 = yes, 0 = no).", ("0", "1")),
    "AUDIO_BITRATE":     ("192k",   "br",   "AAC bitrate when the audio is re-encoded.", (64, 320)),
    "FAST":              ("0",      "enum", "Faster peak matching: accept a peak up to 0.3 dB below the target (never above). 1 = fast, 0 = strict (0.05 dB).", ("0", "1")),
    "WORKERS":           ("2",      "enum", "How many videos are processed at the same time (1-4). More = faster, uses more CPU and battery.", ("1", "2", "3", "4")),
    "YT_DLP_CHANNEL":    ("master", "enum", "yt-dlp update channel: master = newest canary (more regressions), nightly = recommended development snapshots, stable = monthly stable releases.", ("master", "nightly", "stable")),
    "FFMPEG_LOGLEVEL":   ("info",   "enum", "How much ffmpeg writes to the log.", ("quiet", "error", "warning", "info", "verbose")),
}


def validate(key, val):
    if key not in SCHEMA:
        raise ValueError("unknown setting: %s" % key)
    val = str(val).strip()
    _, kind, _, extra = SCHEMA[key]
    if kind == "num":
        if not re.fullmatch(r"-?\d{1,3}(\.\d{1,2})?", val):
            raise ValueError("%s must be a number like -9 or -1.0" % key)
        if not (extra[0] <= float(val) <= extra[1]):
            raise ValueError("%s must be between %g and %g" % (key, extra[0], extra[1]))
    elif kind == "pct":
        if not re.fullmatch(r"\d{1,3}(\.\d{1,2})?", val) or not (extra[0] <= float(val) <= extra[1]):
            raise ValueError("%s must be a number from 0 to 100" % key)
    elif kind == "enum":
        if val not in extra:
            raise ValueError("%s must be one of: %s" % (key, ", ".join(extra)))
    elif kind == "br":
        m = re.fullmatch(r"(\d{2,3})k", val)
        if not m or not (extra[0] <= int(m.group(1)) <= extra[1]):
            raise ValueError("%s must look like 192k (64k to 320k)" % key)
    return val


def read_config():
    vals = {}
    try:
        with open(CONFIG, encoding="utf-8") as f:
            for line in f:
                m = re.fullmatch(r"([A-Z_]+)=([\"']?)([A-Za-z0-9._-]*)\2\s*", line)
                if m and m.group(1) in SCHEMA:
                    try:
                        vals[m.group(1)] = validate(m.group(1), m.group(3))
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass
    return vals


def write_config(vals):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    tmp = "%s.%d.tmp" % (CONFIG, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# Written by the Web UI. Only these settings are read; edit via the UI or here.\n")
        for k in SCHEMA:
            if k in vals:
                f.write("%s=%s\n" % (k, vals[k]))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, CONFIG)


def run(args, timeout=60):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return p.returncode, (p.stdout + p.stderr).strip()
    except Exception as e:  # noqa: BLE001
        return 99, str(e)


def qctl(*a):
    return run([PY, os.path.join(HERE, "qctl.py"), *a])


def worker_state():
    stop_req = os.path.exists(os.path.join(QUEUE_DIR, ".stop"))
    try:
        with open(os.path.join(QUEUE_DIR, ".worker.lock", "pid"), encoding="utf-8") as f:
            pid = int(f.read().strip())
        if _qctl._pid_alive(pid):
            return {"running": True, "pid": pid, "stop_requested": stop_req}
    except (OSError, ValueError):
        pass
    return {"running": False, "pid": None, "stop_requested": False}


def jobs(status=None):
    try:
        return [j for j in _qctl.load_all(repair=False) if not status or j["status"] == status]
    except OSError:
        return []


EVENT_RE = re.compile(r"^\[\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\] \[")
ERR_RE = re.compile(r"(error|fail|warn|bvc2|traceback|exception|403|forbidden|cannot parse|gave up)", re.I)


def tail_log(n, events=False, errors=False):
    """Last n lines; events=True keeps pipeline lines; errors=True keeps warnings/errors."""
    try:
        with open(LOG, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - (1024 * 1024 if errors else 400 * 1024)))
            data = f.read().decode("utf-8", "replace")
    except OSError:
        return []
    lines = data.splitlines()
    if errors:
        lines = [l for l in lines if ERR_RE.search(l) and "CALIBRATE #" not in l and "OUTPUT PEAK:" not in l]
    elif events:
        lines = [l for l in lines if EVENT_RE.match(l)]
    return lines[-n:]


URL_RE = re.compile(r"https?://[^\s<>\"']+")


def _clean_url(u):
    u = u.rstrip(".,;!?")
    while u.endswith(")") and u.count(")") > u.count("("):
        u = u[:-1].rstrip(".,;!?")
    return u


def add_items(text):
    results = []
    for line in text.replace("\r", "\n").split("\n"):
        line = line.strip()
        if not line:
            continue
        urls = URL_RE.findall(line)
        if urls:
            targets = [("--url", _clean_url(u)) for u in urls]
        elif line.startswith("/"):
            targets = [("--file", line)]
        else:
            results.append({"item": line[:200], "ok": False, "msg": "not a link or an absolute file path"})
            continue
        for flag, v in targets:
            rc, out = qctl("add", flag, v)
            results.append({"item": v[:200], "ok": rc == 0, "msg": out.splitlines()[-1] if out else ""})
    if any(r["ok"] for r in results):
        run(["bash", os.path.join(HERE, "q.sh"), "bg"])
    return results


def _parse_int(val, default, lo, hi, name="parameter"):
    if val is None or val == "":
        return default
    try:
        n = int(val)
    except (TypeError, ValueError) as e:
        raise ValueError("invalid %s" % name) from e
    return max(lo, min(n, hi))


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "qui"

    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json", extra=None):
        if not isinstance(body, bytes):
            body = (json.dumps(body) if ctype == "application/json" else body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-ancestors 'none'",
        )
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def guard(self, post):
        host = (self.headers.get("Host") or "").lower()
        if LOOPBACK:
            ok = {"127.0.0.1:%d" % PORT, "localhost:%d" % PORT, "[::1]:%d" % PORT}
            if host not in ok:
                self.send(403, {"error": "bad host"})
                return False
        origin = self.headers.get("Origin")
        if origin and origin.lower() != "http://" + host:
            self.send(403, {"error": "bad origin"})
            return False
        if post and self.headers.get("X-Requested-With") != "q-ui":
            self.send(403, {"error": "missing header"})
            return False
        if not LOOPBACK:
            try:
                with open(os.path.join(DATA_DIR, "webui.token"), encoding="utf-8") as f:
                    tok = f.read().strip()
            except OSError:
                self.send(500, {"error": "token unavailable"})
                return False
            q = parse_qs(urlsplit(self.path).query).get("t", [""])[0]
            ck = SimpleCookie()
            try:
                ck.load(self.headers.get("Cookie") or "")
            except Exception:  # noqa: BLE001
                pass
            ck_val = ck["qt"].value if "qt" in ck else ""
            if q and secrets.compare_digest(q, tok):
                self._set_cookie = "qt=%s; HttpOnly; SameSite=Strict; Path=/" % tok
            elif not (ck_val and secrets.compare_digest(ck_val, tok)):
                self.send(401, {"error": "token required"})
                return False
        return True

    def body_json(self):
        raw_len = self.headers.get("Content-Length") or "0"
        try:
            n = int(raw_len)
        except ValueError as e:
            raise ValueError("invalid Content-Length") from e
        if n < 0 or n > MAX_BODY:
            raise ValueError("body too large")
        if "application/json" not in (self.headers.get("Content-Type") or ""):
            raise ValueError("JSON required")
        data = json.loads(self.rfile.read(n) or b"{}")
        if not isinstance(data, dict):
            raise ValueError("JSON object required")
        return data

    def do_GET(self):
        self._set_cookie = None
        if not self.guard(False):
            return
        u = urlsplit(self.path)
        q = parse_qs(u.query)
        extra = {"Set-Cookie": self._set_cookie} if self._set_cookie else None
        try:
            if u.path in ("/", "/index.html"):
                with open(os.path.join(HERE, "webui.html"), "rb") as f:
                    return self.send(200, f.read(), "text/html", extra)
            if u.path == "/api/status":
                js = jobs()
                st = {s: 0 for s in ("pending", "running", "done", "failed")}
                for j in js:
                    st[j["status"]] += 1
                running = [
                    {"id": j["id"], "value": j["value"], "since": j["updated"], "type": j["type"]}
                    for j in js
                    if j["status"] == "running"
                ]
                cur = running[0] if running else None
                return self.send(
                    200,
                    {"stats": st, "worker": worker_state(), "now": time.time(), "current": cur, "running": running},
                    extra=extra,
                )
            if u.path == "/api/jobs":
                s = q.get("status", [""])[0] or None
                if s and s not in ("pending", "running", "done", "failed"):
                    return self.send(400, {"error": "bad status"})
                lim = _parse_int(q.get("limit", ["200"])[0], 200, 1, 500, "limit")
                js = sorted(jobs(s), key=lambda j: j["id"], reverse=True)[:lim]
                for j in js:
                    j.pop("key", None)
                return self.send(200, {"jobs": js})
            if u.path == "/api/logs":
                n = _parse_int(q.get("n", ["200"])[0], 200, 1, 1000, "n")
                return self.send(
                    200,
                    {"lines": tail_log(n, q.get("events", ["0"])[0] == "1", q.get("errors", ["0"])[0] == "1")},
                )
            if u.path == "/api/config":
                vals = read_config()
                return self.send(
                    200,
                    {
                        "values": {k: vals.get(k, v[0]) for k, v in SCHEMA.items()},
                        "defaults": {k: v[0] for k, v in SCHEMA.items()},
                        "help": {k: v[2] for k, v in SCHEMA.items()},
                        "choices": {k: list(v[3]) for k, v in SCHEMA.items() if v[1] == "enum"},
                        "custom": sorted(vals),
                    },
                )
            if u.path == "/api/fennec":
                n = _parse_int(q.get("limit", ["25"])[0], 25, 1, 50, "limit")
                rc, out = run(["bash", os.path.join(HERE, "q.sh"), "fennec", "--json", str(n)], timeout=20)
                if rc != 0:
                    return self.send(500, {"error": out or "Failed to read Fennec history"})
                try:
                    items = json.loads(out or "[]")
                except ValueError:
                    return self.send(500, {"error": "Invalid Fennec output"})
                return self.send(200, {"items": items}, extra=extra)
        except ValueError as e:
            return self.send(400, {"error": str(e)})
        except OSError as e:
            return self.send(500, {"error": "storage error: %s" % e})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        self._set_cookie = None
        if not self.guard(True):
            return
        path = urlsplit(self.path).path
        try:
            b = self.body_json()
            if path == "/api/add":
                return self.send(200, {"results": add_items(str(b.get("items", ""))[:20000])})
            if path == "/api/retry":
                rc, out = qctl("retry", "--all") if b.get("all") else qctl("retry", str(int(b["id"])))
                if rc == 0:
                    run(["bash", os.path.join(HERE, "q.sh"), "bg"])
                return self.send(200, {"ok": rc == 0, "msg": out})
            if path == "/api/remove":
                rc, out = qctl("remove", str(int(b["id"])))
                return self.send(200, {"ok": rc == 0, "msg": out})
            if path == "/api/clear":
                raw_st = b.get("statuses", [])
                if not isinstance(raw_st, list):
                    raise ValueError("statuses must be a list")
                st = [s for s in raw_st if s in ("done", "failed")]
                if not st:
                    return self.send(400, {"error": "choose done and/or failed"})
                rc, out = qctl("clear", *st)
                return self.send(200, {"ok": rc == 0, "msg": out})
            if path == "/api/worker":
                act = b.get("action")
                if act not in ("start", "stop"):
                    return self.send(400, {"error": "bad action"})
                rc, out = run(["bash", os.path.join(HERE, "q.sh"), "bg" if act == "start" else "stop"])
                return self.send(200, {"ok": rc == 0, "msg": out})
            if path == "/api/config":
                cur = read_config()
                if b.get("reset"):
                    cur = {}
                updates = b.get("values")
                if updates is not None and not isinstance(updates, dict):
                    raise ValueError("values must be an object")
                for k, v in (updates or {}).items():
                    v = validate(k, v)
                    if v == SCHEMA[k][0]:
                        cur.pop(k, None)
                    else:
                        cur[k] = v
                write_config(cur)
                return self.send(200, {"ok": True, "custom": sorted(cur)})
        except (ValueError, KeyError, TypeError) as e:
            return self.send(400, {"error": str(e)})
        except OSError as e:
            return self.send(500, {"error": "storage error: %s" % e})
        self.send(404, {"error": "not found"})


def main():
    if "-h" in sys.argv or "--help" in sys.argv:
        print(__doc__)
        return
    if not LOOPBACK:
        os.makedirs(DATA_DIR, exist_ok=True)
        tp = os.path.join(DATA_DIR, "webui.token")
        if not os.path.exists(tp):
            fd = os.open(tp, os.O_WRONLY | os.O_CREAT, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(secrets.token_urlsafe(24))
        with open(tp, encoding="utf-8") as f:
            tok = f.read().strip()
        print("Token for other devices: open  http://<phone-ip>:%d/?t=%s" % (PORT, tok), flush=True)
    srv = ThreadingHTTPServer((HOST, PORT), H)
    srv.daemon_threads = True
    print("Web UI on http://%s:%d" % (HOST, PORT), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
