#!/usr/bin/env python3
"""
Persistent FIFO Queue Manager for Termux & PC Media Pipeline.

Handles:
- Multiple URLs and local video files
- Sequential FIFO scheduling
- Duplicate job prevention
- Safe recovery of interrupted jobs
- Low storage I/O with atomic state persistence
"""

import os
import sys
import json
import time
import re
import tempfile
from datetime import datetime, timezone

try:
    import fcntl
except ImportError:
    fcntl = None

# Base directory discovery
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
QUEUE_FILE = os.path.join(SCRIPT_DIR, "queue.json")
LOCK_FILE = os.path.join(SCRIPT_DIR, ".queue.lock")


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


class QueueLock:
    """Cross-platform file lock for queue state operations."""
    def __init__(self, lock_path=LOCK_FILE):
        self.lock_path = lock_path
        self.file_obj = None

    def __enter__(self):
        try:
            self.file_obj = open(self.lock_path, "w")
            if fcntl:
                fcntl.flock(self.file_obj.fileno(), fcntl.LOCK_EX)
        except Exception:
            pass
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        try:
            if self.file_obj:
                if fcntl:
                    fcntl.flock(self.file_obj.fileno(), fcntl.LOCK_UN)
                self.file_obj.close()
        except Exception:
            pass


def _default_state():
    return {
        "version": 1,
        "worker_status": "idle",  # "idle" | "processing" | "paused" | "stopped"
        "worker_pid": None,
        "current_job_id": None,
        "updated_at": _now_iso(),
        "jobs": []
    }


def load_queue():
    """Load queue state with corrupted-file fallback."""
    if not os.path.exists(QUEUE_FILE):
        return _default_state()
    try:
        with open(QUEUE_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            if not isinstance(data, dict) or "jobs" not in data:
                return _default_state()
            return data
    except Exception as e:
        sys.stderr.write(f"[WARN] Failed to read queue.json ({e}), resetting to default state.\n")
        return _default_state()


def save_queue(state):
    """Atomically save queue state via temporary file and rename to avoid partial writes."""
    state["updated_at"] = _now_iso()
    temp_dir = os.path.dirname(QUEUE_FILE) or "."
    try:
        with tempfile.NamedTemporaryFile("w", dir=temp_dir, delete=False, encoding="utf-8") as tf:
            json.dump(state, tf, indent=2, ensure_ascii=False)
            tf.flush()
            os.fsync(tf.fileno())
            temp_name = tf.name
        os.replace(temp_name, QUEUE_FILE)
    except Exception as e:
        sys.stderr.write(f"[ERROR] Failed to save queue.json: {e}\n")
        if 'temp_name' in locals() and os.path.exists(temp_name):
            try:
                os.remove(temp_name)
            except OSError:
                pass
        raise


def extract_urls(text):
    """Extract all valid HTTP/HTTPS URLs from any text string or intent payload."""
    pattern = r'https?://[^\s<>"\',;]+'
    matches = re.findall(pattern, text)
    cleaned = []
    for m in matches:
        # Strip trailing punctuation that might attach to URLs in chat/social shares
        u = re.sub(r'[\.,;:!?\)>]+$', '', m)
        if u and u not in cleaned:
            cleaned.append(u)
    return cleaned


def normalize_job_payload(raw):
    """Determine job type and sanitize payload."""
    raw = raw.strip()
    urls = extract_urls(raw)
    if urls:
        return "url", urls[0]
    # Check if local file
    expanded = os.path.expanduser(raw)
    if os.path.exists(expanded):
        return "file", os.path.abspath(expanded)
    if raw.startswith("/") or re.match(r'^[a-zA-Z]:[\\/]', raw):
        return "file", expanded
    if raw.lower() == "batch":
        return "batch", "batch"
    return "url", raw


def add_job(raw_payload, extra_info=None):
    """
    Add a single URL, file, or batch job to the persistent queue.
    Prevents duplicates if an identical payload is pending or currently processing.
    """
    job_type, clean_payload = normalize_job_payload(raw_payload)

    with QueueLock():
        state = load_queue()

        # Duplicate check: prevent duplicate pending/processing jobs
        for job in state["jobs"]:
            if job.get("status") in ("pending", "processing"):
                if job.get("payload") == clean_payload:
                    return {
                        "success": False,
                        "duplicate": True,
                        "job": job,
                        "message": f"Job already exists in queue [{job['status']}] (ID: {job['id']})"
                    }

        job_id = f"job_{int(time.time())}_{os.urandom(2).hex()}"
        display_name = os.path.basename(clean_payload) if job_type == "file" else clean_payload

        new_job = {
            "id": job_id,
            "type": job_type,
            "payload": clean_payload,
            "display_name": display_name,
            "status": "pending",
            "created_at": _now_iso(),
            "started_at": None,
            "completed_at": None,
            "retries": 0,
            "error": None,
            "extra_info": extra_info or {}
        }

        state["jobs"].append(new_job)
        save_queue(state)

        return {
            "success": True,
            "duplicate": False,
            "job": new_job,
            "message": f"Enqueued job {job_id} ({job_type})"
        }


def add_multi(text_or_lines):
    """Add multiple URLs or files in one batch."""
    if isinstance(text_or_lines, str):
        lines = [line.strip() for line in text_or_lines.strip().splitlines() if line.strip()]
    else:
        lines = [str(x).strip() for x in text_or_lines if str(x).strip()]

    results = []
    # If text has multiple URLs on one line, extract all URLs
    all_items = []
    for line in lines:
        urls = extract_urls(line)
        if len(urls) > 1:
            all_items.extend(urls)
        else:
            all_items.append(line)

    for item in all_items:
        res = add_job(item)
        results.append(res)
    return results


def recover_interrupted_jobs():
    """Reset any jobs that were 'processing' when the worker or phone died."""
    with QueueLock():
        state = load_queue()
        recovered = 0
        for job in state["jobs"]:
            if job.get("status") == "processing":
                job["status"] = "pending"
                job["retries"] = job.get("retries", 0) + 1
                job["error"] = "Recovered after process interruption"
                job["started_at"] = None
                recovered += 1
        if state.get("current_job_id"):
            state["current_job_id"] = None
        if state.get("worker_status") == "processing":
            state["worker_status"] = "idle"
        if recovered > 0:
            save_queue(state)
        return recovered


def get_next_pending_job():
    """Retrieve the next pending job in FIFO order."""
    with QueueLock():
        state = load_queue()
        for job in state["jobs"]:
            if job.get("status") == "pending":
                return job
        return None


def mark_job_started(job_id):
    """Transition job to processing state."""
    with QueueLock():
        state = load_queue()
        for job in state["jobs"]:
            if job["id"] == job_id:
                job["status"] = "processing"
                job["started_at"] = _now_iso()
                state["current_job_id"] = job_id
                state["worker_status"] = "processing"
                save_queue(state)
                return job
        return None


def mark_job_completed(job_id, result_info=None):
    """Transition job to completed state."""
    with QueueLock():
        state = load_queue()
        target = None
        for job in state["jobs"]:
            if job["id"] == job_id:
                job["status"] = "completed"
                job["completed_at"] = _now_iso()
                job["error"] = None
                if result_info:
                    job["result_info"] = result_info
                target = job
                break
        if state.get("current_job_id") == job_id:
            state["current_job_id"] = None
            state["worker_status"] = "idle"
        save_queue(state)
        return target


def mark_job_failed(job_id, error_message):
    """Transition job to failed state with error message."""
    with QueueLock():
        state = load_queue()
        target = None
        for job in state["jobs"]:
            if job["id"] == job_id:
                job["status"] = "failed"
                job["completed_at"] = _now_iso()
                job["error"] = str(error_message)
                target = job
                break
        if state.get("current_job_id") == job_id:
            state["current_job_id"] = None
            state["worker_status"] = "idle"
        save_queue(state)
        return target


def retry_job(job_id):
    """Reset a specific failed or completed job back to pending."""
    with QueueLock():
        state = load_queue()
        for job in state["jobs"]:
            if job["id"] == job_id:
                job["status"] = "pending"
                job["started_at"] = None
                job["completed_at"] = None
                job["error"] = None
                save_queue(state)
                return True
        return False


def retry_all_failed():
    """Reset all failed jobs back to pending."""
    with QueueLock():
        state = load_queue()
        count = 0
        for job in state["jobs"]:
            if job.get("status") == "failed":
                job["status"] = "pending"
                job["started_at"] = None
                job["completed_at"] = None
                job["error"] = None
                count += 1
        if count > 0:
            save_queue(state)
        return count


def delete_job(job_id):
    """Remove a job from the queue."""
    with QueueLock():
        state = load_queue()
        before = len(state["jobs"])
        state["jobs"] = [j for j in state["jobs"] if j["id"] != job_id]
        if len(state["jobs"]) < before:
            if state.get("current_job_id") == job_id:
                state["current_job_id"] = None
                state["worker_status"] = "idle"
            save_queue(state)
            return True
        return False


def clear_completed(include_failed=False):
    """Clear completed (and optionally failed) jobs from queue history."""
    with QueueLock():
        state = load_queue()
        before = len(state["jobs"])
        statuses = ("completed",) if not include_failed else ("completed", "failed")
        state["jobs"] = [j for j in state["jobs"] if j.get("status") not in statuses]
        removed = before - len(state["jobs"])
        if removed > 0:
            save_queue(state)
        return removed


def get_queue_summary():
    """Return counts and high-level queue metrics."""
    state = load_queue()
    counts = {"pending": 0, "processing": 0, "completed": 0, "failed": 0, "total": 0}
    for j in state["jobs"]:
        s = j.get("status", "unknown")
        if s in counts:
            counts[s] += 1
        counts["total"] += 1
    return {
        "counts": counts,
        "worker_status": state.get("worker_status", "idle"),
        "current_job_id": state.get("current_job_id"),
        "updated_at": state.get("updated_at")
    }


def cli_main():
    if len(sys.argv) < 2:
        print("Usage: queue_manager.py <command> [arguments...]")
        print("Commands:")
        print("  add <URL|FILE|multi-line-text>   Add one or more items to FIFO queue")
        print("  list [pending|failed|all]        Display jobs in queue")
        print("  status                           Display queue counts and worker state")
        print("  next                             Print next pending job JSON")
        print("  recover                          Recover any interrupted jobs")
        print("  retry <job_id>                   Retry a failed job")
        print("  retry-all                        Retry all failed jobs")
        print("  delete <job_id>                  Delete a job from queue")
        print("  clear [failed]                   Clear completed (or failed) jobs")
        sys.exit(1)

    cmd = sys.argv[1].lower()

    if cmd == "add":
        if len(sys.argv) < 3:
            # Read from stdin if piped
            raw = sys.stdin.read().strip()
        else:
            raw = " ".join(sys.argv[2:])
        if not raw:
            print("[ERROR] No input URL or file provided.", file=sys.stderr)
            sys.exit(2)
        results = add_multi(raw)
        for r in results:
            if r["duplicate"]:
                print(f"[DUPLICATE] {r['message']}")
            elif r["success"]:
                print(f"[OK] {r['message']}: {r['job']['payload']}")
            else:
                print(f"[FAIL] {r['message']}")
        sys.exit(0)

    elif cmd == "list":
        filter_status = sys.argv[2] if len(sys.argv) > 2 else "all"
        state = load_queue()
        jobs = state["jobs"]
        if filter_status != "all":
            jobs = [j for j in jobs if j.get("status") == filter_status]
        print(f"Queue: {len(jobs)} jobs (Filter: {filter_status})")
        for j in jobs:
            err = f" | Err: {j['error']}" if j.get("error") else ""
            print(f"[{j['status'].upper():10s}] {j['id']} ({j['type']}) {j['payload']}{err}")
        sys.exit(0)

    elif cmd == "status":
        summary = get_queue_summary()
        print(json.dumps(summary, indent=2))
        sys.exit(0)

    elif cmd == "next":
        job = get_next_pending_job()
        if job:
            print(json.dumps(job))
            sys.exit(0)
        else:
            sys.exit(1)

    elif cmd == "recover":
        n = recover_interrupted_jobs()
        print(f"Recovered {n} interrupted jobs.")
        sys.exit(0)

    elif cmd == "retry":
        if len(sys.argv) < 3:
            print("Usage: queue_manager.py retry <job_id>", file=sys.stderr)
            sys.exit(2)
        jid = sys.argv[2]
        if retry_job(jid):
            print(f"[OK] Job {jid} reset to pending.")
            sys.exit(0)
        else:
            print(f"[ERROR] Job {jid} not found.", file=sys.stderr)
            sys.exit(1)

    elif cmd == "retry-all":
        n = retry_all_failed()
        print(f"[OK] Reset {n} failed jobs to pending.")
        sys.exit(0)

    elif cmd == "delete":
        if len(sys.argv) < 3:
            print("Usage: queue_manager.py delete <job_id>", file=sys.stderr)
            sys.exit(2)
        jid = sys.argv[2]
        if delete_job(jid):
            print(f"[OK] Job {jid} deleted.")
            sys.exit(0)
        else:
            print(f"[ERROR] Job {jid} not found.", file=sys.stderr)
            sys.exit(1)

    elif cmd == "clear":
        include_failed = len(sys.argv) > 2 and sys.argv[2].lower() in ("failed", "all")
        n = clear_completed(include_failed=include_failed)
        print(f"[OK] Cleared {n} jobs.")
        sys.exit(0)

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    cli_main()
