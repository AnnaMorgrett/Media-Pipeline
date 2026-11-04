#!/usr/bin/env python3
"""
Mobile-Friendly Web UI Server & REST API for Termux & PC Media Pipeline.

Features:
- Mobile-optimized interface for phone browsers & desktop
- Real-time queue management (add URLs, retry, delete, clear)
- Live worker status & background processing control
- Visual configuration editor (Audio normalization -9 LUFS, true-peak ceiling, etc.)
- Live rolling log viewer with filtering & auto-scroll
- One-click safe Git updates
"""

import os
import sys
import json
import time
import subprocess
import shutil
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

import queue_manager

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
WEB_DIR = os.path.join(SCRIPT_DIR, "web")
CONFIG_FILE = os.path.join(SCRIPT_DIR, "config.env")
CONFIG_EXAMPLE = os.path.join(SCRIPT_DIR, "config.env.example")
LOG_FILE = os.path.join(SCRIPT_DIR, "media_processor_log.txt")
PID_FILE = os.path.join(SCRIPT_DIR, ".webui.pid")
WORKER_PID_FILE = os.path.join(SCRIPT_DIR, ".worker.pid")
MASTER_RUN_SH = os.path.join(SCRIPT_DIR, "master_run.sh")
QUEUE_WORKER_SH = os.path.join(SCRIPT_DIR, "queue_worker.sh")
UPDATE_SH = os.path.join(SCRIPT_DIR, "update.sh")


def get_bash_cmd():
    """Discover bash binary across Android Termux, Linux, macOS, and Windows."""
    if shutil.which("bash"):
        return ["bash"]
    for p in [
        r"C:\Program Files\Git\bin\bash.exe",
        r"C:\Program Files (x86)\Git\bin\bash.exe",
        os.path.expandvars(r"%LOCALAPPDATA%\Programs\Git\bin\bash.exe"),
        r"C:\msys64\usr\bin\bash.exe",
    ]:
        if os.path.exists(p):
            return [p]
    return ["bash"]


def run_bash_script(script_path, *args, timeout=None):
    """Safely run a shell script without crashing if shell environment is unavailable."""
    try:
        cmd = get_bash_cmd() + [script_path] + list(args)
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=timeout)
    except Exception as e:
        sys.stderr.write(f"[WARN] Error running script {script_path}: {e}\n")
        return None


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def load_config_dict():
    """Load config.env into a dictionary."""
    config = {
        "TARGET_LUFS": "-9",
        "MAX_TRUE_PEAK": "-0.5",
        "AUDIO_BITRATE": "192k",
        "LOG_MAX_BYTES": "2097152",
        "MEDIA_DIR": "/storage/emulated/0" if (os.path.exists("/data/data/com.termux") or os.environ.get("TERMUX_VERSION")) else os.path.expanduser("~/TermuxMedia"),
        "WEB_UI_HOST": "0.0.0.0",
        "WEB_UI_PORT": "8080",
        "AUTO_UPDATE_YTDLP": "true"
    }
    src_file = CONFIG_FILE if os.path.exists(CONFIG_FILE) else CONFIG_EXAMPLE
    if os.path.exists(src_file):
        try:
            with open(src_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        k = k.strip()
                        v = v.strip().strip('"').strip("'")
                        config[k] = v
        except Exception as e:
            sys.stderr.write(f"[WARN] Error reading config: {e}\n")
    return config


def save_config_dict(new_settings):
    """Save dictionary back to config.env preserving comments where possible."""
    current = load_config_dict()
    current.update(new_settings)

    content = [
        "# ═══════════════════════════════════════════════════════════════════════════════",
        "#  Termux & PC Media Processing Pipeline - Configuration File",
        f"#  Updated via Web UI on {time.strftime('%Y-%m-%d %H:%M:%S')}",
        "# ═══════════════════════════════════════════════════════════════════════════════",
        "",
        f'TARGET_LUFS="{current.get("TARGET_LUFS", "-9")}"',
        f'MAX_TRUE_PEAK="{current.get("MAX_TRUE_PEAK", "-0.5")}"',
        f'AUDIO_BITRATE="{current.get("AUDIO_BITRATE", "192k")}"',
        f'LOG_MAX_BYTES="{current.get("LOG_MAX_BYTES", "2097152")}"',
        f'MEDIA_DIR="{current.get("MEDIA_DIR", "")}"',
        f'WEB_UI_HOST="{current.get("WEB_UI_HOST", "0.0.0.0")}"',
        f'WEB_UI_PORT="{current.get("WEB_UI_PORT", "8080")}"',
        f'AUTO_UPDATE_YTDLP="{current.get("AUTO_UPDATE_YTDLP", "true")}"',
        ""
    ]
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(content))


def is_worker_active():
    """Check if background worker process is currently running."""
    if os.path.exists(WORKER_PID_FILE):
        try:
            with open(WORKER_PID_FILE, "r") as f:
                pid = int(f.read().strip())
            os.kill(pid, 0)
            return True, pid
        except Exception:
            return False, None
    return False, None


def get_system_stats():
    """Fetch high-level system metrics."""
    config = load_config_dict()
    media_dir = config.get("MEDIA_DIR") or ("/storage/emulated/0" if os.path.exists("/data/data/com.termux") else os.path.expanduser("~/TermuxMedia"))
    disk_info = {"total": 0, "free": 0, "used": 0, "path": media_dir}
    try:
        if os.path.exists(media_dir):
            usage = shutil.disk_usage(media_dir)
            disk_info = {
                "total": usage.total,
                "free": usage.free,
                "used": usage.used,
                "path": media_dir
            }
    except Exception:
        pass

    worker_running, worker_pid = is_worker_active()
    queue_summary = queue_manager.get_queue_summary()

    return {
        "worker_running": worker_running,
        "worker_pid": worker_pid,
        "worker_status": queue_summary.get("worker_status", "idle"),
        "current_job_id": queue_summary.get("current_job_id"),
        "counts": queue_summary.get("counts", {}),
        "disk": disk_info,
        "config": {
            "TARGET_LUFS": config.get("TARGET_LUFS", "-9"),
            "MAX_TRUE_PEAK": config.get("MAX_TRUE_PEAK", "-0.5"),
            "AUDIO_BITRATE": config.get("AUDIO_BITRATE", "192k")
        },
        "is_termux": os.path.exists("/data/data/com.termux") or bool(os.environ.get("TERMUX_VERSION")),
        "time": time.strftime("%Y-%m-%d %H:%M:%S")
    }


class ApiHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Silence routine HTTP access logs to keep terminal clean
        pass

    def _send_json(self, data, status_code=200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, message, status_code=400):
        self._send_json({"success": False, "error": message}, status_code)

    def _read_json_body(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length <= 0:
                return {}
            raw = self.rfile.read(length).decode("utf-8")
            return json.loads(raw)
        except Exception as e:
            return None

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        # REST API Routes
        if path == "/api/status":
            stats = get_system_stats()
            self._send_json({"success": True, "data": stats})
            return

        elif path == "/api/queue":
            query = urllib.parse.parse_qs(parsed.query)
            status_filter = query.get("status", ["all"])[0]
            state = queue_manager.load_queue()
            jobs = state.get("jobs", [])
            if status_filter != "all":
                jobs = [j for j in jobs if j.get("status") == status_filter]
            self._send_json({
                "success": True,
                "jobs": jobs,
                "worker_status": state.get("worker_status", "idle"),
                "current_job_id": state.get("current_job_id")
            })
            return

        elif path == "/api/config":
            cfg = load_config_dict()
            self._send_json({"success": True, "config": cfg})
            return

        elif path == "/api/logs":
            query = urllib.parse.parse_qs(parsed.query)
            max_lines = int(query.get("lines", [250])[0])
            filter_text = query.get("filter", [""])[0].lower()
            lines = []
            if os.path.exists(LOG_FILE):
                try:
                    with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as f:
                        all_lines = f.readlines()
                    if filter_text:
                        all_lines = [l for l in all_lines if filter_text in l.lower()]
                    lines = all_lines[-max_lines:]
                except Exception as e:
                    lines = [f"[ERROR] Could not read log file: {e}"]
            self._send_json({"success": True, "lines": lines, "total": len(lines)})
            return

        elif path == "/api/system/check_update":
            output = ""
            try:
                subprocess.run(["git", "fetch", "origin"], cwd=SCRIPT_DIR, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
                local_h = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=SCRIPT_DIR, text=True).strip()
                remote_h = subprocess.check_output(["git", "rev-parse", "origin/main"], cwd=SCRIPT_DIR, text=True).strip()
                commit_msg = subprocess.check_output(["git", "log", "-1", "--pretty=%s"], cwd=SCRIPT_DIR, text=True).strip()
                has_updates = (local_h != remote_h)
                self._send_json({
                    "success": True,
                    "has_updates": has_updates,
                    "local_commit": local_h[:7],
                    "remote_commit": remote_h[:7],
                    "commit_msg": commit_msg
                })
            except Exception as e:
                self._send_json({
                    "success": True,
                    "has_updates": False,
                    "error": str(e),
                    "local_commit": "unknown",
                    "remote_commit": "unknown"
                })
            return

        # Static File Serving (Web UI)
        self._serve_static(path)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        body = self._read_json_body()
        if body is None:
            self._send_error("Invalid JSON body", 400)
            return

        if path == "/api/queue/add":
            raw_input = body.get("input", "") or body.get("url", "") or body.get("file", "")
            if not raw_input:
                self._send_error("No input URL or file provided")
                return

            results = queue_manager.add_multi(raw_input)
            # Wake up worker
            run_bash_script(QUEUE_WORKER_SH, "start")
            self._send_json({"success": True, "results": results})
            return

        elif path == "/api/queue/retry":
            job_id = body.get("job_id")
            if body.get("all"):
                n = queue_manager.retry_all_failed()
                run_bash_script(QUEUE_WORKER_SH, "start")
                self._send_json({"success": True, "message": f"Reset {n} failed jobs to pending"})
            elif job_id:
                ok = queue_manager.retry_job(job_id)
                if ok:
                    run_bash_script(QUEUE_WORKER_SH, "start")
                    self._send_json({"success": True, "message": f"Job {job_id} reset to pending"})
                else:
                    self._send_error(f"Job {job_id} not found", 404)
            else:
                self._send_error("Missing job_id or all=true")
            return

        elif path == "/api/queue/delete":
            job_id = body.get("job_id")
            if not job_id:
                self._send_error("Missing job_id")
                return
            ok = queue_manager.delete_job(job_id)
            if ok:
                self._send_json({"success": True, "message": f"Job {job_id} deleted"})
            else:
                self._send_error(f"Job {job_id} not found", 404)
            return

        elif path == "/api/queue/clear_completed":
            inc_failed = bool(body.get("include_failed", False))
            n = queue_manager.clear_completed(include_failed=inc_failed)
            self._send_json({"success": True, "message": f"Cleared {n} jobs"})
            return

        elif path == "/api/queue/worker":
            action = body.get("action", "")
            if action == "start":
                run_bash_script(QUEUE_WORKER_SH, "start")
                self._send_json({"success": True, "message": "Worker started"})
            elif action == "stop":
                run_bash_script(QUEUE_WORKER_SH, "stop")
                self._send_json({"success": True, "message": "Worker stopped"})
            elif action == "pause":
                with queue_manager.QueueLock():
                    st = queue_manager.load_queue()
                    st["worker_status"] = "paused"
                    queue_manager.save_queue(st)
                self._send_json({"success": True, "message": "Worker paused"})
            elif action == "resume":
                with queue_manager.QueueLock():
                    st = queue_manager.load_queue()
                    st["worker_status"] = "idle"
                    queue_manager.save_queue(st)
                run_bash_script(QUEUE_WORKER_SH, "start")
                self._send_json({"success": True, "message": "Worker resumed"})
            else:
                self._send_error("Invalid worker action")
            return

        elif path == "/api/process_now":
            # Trigger immediate batch run via queue_worker.sh run-once or master_run.sh in background
            queue_manager.add_job("batch")
            run_bash_script(QUEUE_WORKER_SH, "start")
            self._send_json({"success": True, "message": "Batch normalization job enqueued and worker triggered."})
            return

        elif path == "/api/config":
            new_settings = body.get("config", {})
            if not isinstance(new_settings, dict):
                self._send_error("Config must be a dictionary")
                return
            save_config_dict(new_settings)
            self._send_json({"success": True, "message": "Configuration saved successfully."})
            return

        elif path == "/api/logs/clear":
            try:
                with open(LOG_FILE, "w", encoding="utf-8") as f:
                    f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [MASTER] Log cleared via Web UI\n")
                self._send_json({"success": True, "message": "Log cleared."})
            except Exception as e:
                self._send_error(str(e))
            return

        elif path == "/api/system/update":
            try:
                cmd = get_bash_cmd() + [UPDATE_SH]
                proc = subprocess.Popen(cmd, cwd=SCRIPT_DIR, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                out, _ = proc.communicate(timeout=60)
                self._send_json({"success": proc.returncode == 0, "output": out})
            except Exception as e:
                self._send_error(f"Update failed: {e}")
            return

        else:
            self._send_error("Not Found", 404)

    def _serve_static(self, path):
        if path in ("", "/"):
            path = "/index.html"
        safe_path = os.path.normpath(path.lstrip("/"))
        file_path = os.path.join(WEB_DIR, safe_path)

        if os.path.exists(file_path) and os.path.isfile(file_path):
            ext = os.path.splitext(file_path)[1].lower()
            mime = {
                ".html": "text/html; charset=utf-8",
                ".css": "text/css; charset=utf-8",
                ".js": "application/javascript; charset=utf-8",
                ".json": "application/json",
                ".svg": "image/svg+xml",
                ".png": "image/png",
                ".ico": "image/x-icon"
            }.get(ext, "application/octet-stream")

            try:
                with open(file_path, "rb") as f:
                    content = f.read()
                self.send_response(200)
                self.send_header("Content-Type", mime)
                self.send_header("Content-Length", str(len(content)))
                self.end_headers()
                self.wfile.write(content)
                return
            except Exception as e:
                self._send_error(f"Error serving file: {e}", 500)
                return

        self._send_error("Static asset not found", 404)


def run_server():
    cfg = load_config_dict()
    host = cfg.get("WEB_UI_HOST", "0.0.0.0")
    port = int(cfg.get("WEB_UI_PORT", 8080))

    server = ThreadedHTTPServer((host, port), ApiHandler)

    # Save PID
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    print(f"==================================================")
    print(f"  Termux Media Pipeline Web UI Server Started     ")
    print(f"  Local URL:   http://127.0.0.1:{port}")
    print(f"  Listening:   http://{host}:{port}")
    print(f"  PID:         {os.getpid()}")
    print(f"==================================================", flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if os.path.exists(PID_FILE):
            try:
                os.remove(PID_FILE)
            except Exception:
                pass


if __name__ == "__main__":
    run_server()
