#!/usr/bin/env python3
"""
Sequential FIFO Background Worker for Termux & PC Media Pipeline.

Processes queued jobs one-by-one:
1. Downloads URLs via download.sh
2. Relocates assets via move_assets.sh
3. Normalizes videos to -9 LUFS via normalize.sh
4. Manages Android wake lock & notification shade updates
5. Recovers interrupted jobs safely on reboot/restart
"""

import os
import sys
import time
import signal
import subprocess
import shutil

import queue_manager

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DOWNLOAD_SH = os.path.join(SCRIPT_DIR, "download.sh")
MASTER_RUN_SH = os.path.join(SCRIPT_DIR, "master_run.sh")
NOTIFICATION_TILE_SH = os.path.join(SCRIPT_DIR, "notification_tile.sh")
CONFIG_FILE = os.path.join(SCRIPT_DIR, "config.env")
LOG_FILE = os.path.join(SCRIPT_DIR, "media_processor_log.txt")

RUNNING = True
CURRENT_PROCESS = None


def sig_handler(signum, frame):
    global RUNNING, CURRENT_PROCESS
    RUNNING = False
    if CURRENT_PROCESS and CURRENT_PROCESS.poll() is None:
        try:
            CURRENT_PROCESS.terminate()
        except Exception:
            pass


signal.signal(signal.SIGINT, sig_handler)
signal.signal(signal.SIGTERM, sig_handler)


def log_worker(msg):
    timestamp = time.strftime('%Y-%m-%d %H:%M:%S')
    line = f"[{timestamp}] [WORKER] {msg}\n"
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass
    print(line.strip(), flush=True)


def acquire_wake_lock():
    """Prevent Android from killing CPU during long video encoding."""
    if shutil.which("termux-wake-lock"):
        try:
            subprocess.run(["termux-wake-lock"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


def release_wake_lock():
    """Release Android CPU wake lock when idle."""
    if shutil.which("termux-wake-unlock"):
        try:
            subprocess.run(["termux-wake-unlock"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


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


def update_notification_shade(status_text=None, job_info=None):
    """Trigger update of the Android notification shade tile."""
    if os.path.exists(NOTIFICATION_TILE_SH):
        try:
            args = get_bash_cmd() + [NOTIFICATION_TILE_SH, "update"]
            if status_text:
                args.extend(["--status", status_text])
            if job_info:
                args.extend(["--job", job_info])
            subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


def get_media_dir():
    """Discover media directory matching pipeline shell scripts."""
    # Check config.env first
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("MEDIA_DIR="):
                        val = line.split("=", 1)[1].strip().strip('"').strip("'")
                        if val:
                            return os.path.expanduser(val)
        except Exception:
            pass
    if os.environ.get("MEDIA_DIR"):
        return os.path.expanduser(os.environ["MEDIA_DIR"])
    if os.path.exists("/data/data/com.termux") or os.environ.get("TERMUX_VERSION"):
        return "/storage/emulated/0"
    return os.path.expanduser("~/TermuxMedia")


def execute_cmd(cmd_list, timeout=None):
    """Run shell command capturing output."""
    global CURRENT_PROCESS
    try:
        CURRENT_PROCESS = subprocess.Popen(
            cmd_list,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )
        output_lines = []
        for line in CURRENT_PROCESS.stdout:
            output_lines.append(line)
            # Write directly to log for real-time visibility
            try:
                with open(LOG_FILE, "a", encoding="utf-8") as f:
                    f.write(line)
            except Exception:
                pass
        CURRENT_PROCESS.wait(timeout=timeout)
        rc = CURRENT_PROCESS.returncode
        CURRENT_PROCESS = None
        return rc, "".join(output_lines)
    except Exception as e:
        CURRENT_PROCESS = None
        return 1, str(e)


def process_url_job(job):
    url = job["payload"]
    log_worker(f"Starting URL download: {url}")
    update_notification_shade("Downloading", f"URL: {url[:30]}...")

    # Step 1: Download with yt-dlp via download.sh
    rc, dl_out = execute_cmd(get_bash_cmd() + [DOWNLOAD_SH, url])
    if rc != 0:
        err_msg = f"yt-dlp download failed with exit code {rc}"
        log_worker(f"ERROR: {err_msg}")
        return False, err_msg

    # Step 2: Ingest and normalize via master_run.sh
    log_worker(f"Invoking master_run.sh for downloaded media: {url}")
    update_notification_shade("Normalizing", f"URL: {url[:30]}...")
    rc_m, master_out = execute_cmd(get_bash_cmd() + [MASTER_RUN_SH])
    if rc_m != 0:
        err_msg = f"Pipeline execution failed with exit code {rc_m}"
        log_worker(f"ERROR: {err_msg}")
        return False, err_msg

    log_worker(f"Successfully processed URL: {url}")
    return True, "Download and normalization completed successfully."


def process_file_job(job):
    src_file = job["payload"]
    log_worker(f"Starting local file ingestion: {src_file}")

    if not os.path.exists(src_file):
        err_msg = f"Source file does not exist: {src_file}"
        log_worker(f"ERROR: {err_msg}")
        return False, err_msg

    media_dir = get_media_dir()
    dl_dir = os.path.join(media_dir, "Download", "yt-dlp")
    os.makedirs(dl_dir, exist_ok=True)

    base_name = os.path.basename(src_file)
    target_dest = os.path.join(dl_dir, base_name)

    # Avoid copying if already in input folders
    if os.path.abspath(src_file) != os.path.abspath(target_dest):
        log_worker(f"Copying shared file {src_file} -> {target_dest}")
        update_notification_shade("Importing file", base_name[:25])
        try:
            shutil.copy2(src_file, target_dest)
        except Exception as e:
            err_msg = f"Failed to copy file to ingest directory: {e}"
            log_worker(f"ERROR: {err_msg}")
            return False, err_msg

    # Run master_run.sh
    log_worker(f"Normalizing file via master_run.sh: {base_name}")
    update_notification_shade("Normalizing", base_name[:25])
    rc_m, master_out = execute_cmd(get_bash_cmd() + [MASTER_RUN_SH])
    if rc_m != 0:
        err_msg = f"Normalization failed with exit code {rc_m}"
        log_worker(f"ERROR: {err_msg}")
        return False, err_msg

    log_worker(f"Successfully processed file: {base_name}")
    return True, f"Normalized {base_name} successfully."


def process_batch_job(job):
    log_worker("Starting batch processing of input directories...")
    update_notification_shade("Batch processing", "Scanning media...")
    rc_m, master_out = execute_cmd(get_bash_cmd() + [MASTER_RUN_SH])
    if rc_m != 0:
        err_msg = f"Batch run failed with exit code {rc_m}"
        log_worker(f"ERROR: {err_msg}")
        return False, err_msg
    log_worker("Batch processing completed successfully.")
    return True, "Batch run completed."


def run_worker_loop(single_run=False, poll_interval=3):
    global RUNNING
    log_worker(f"Queue worker started (PID: {os.getpid()})")

    # Recover any interrupted jobs on startup
    recovered = queue_manager.recover_interrupted_jobs()
    if recovered > 0:
        log_worker(f"Recovered {recovered} previously interrupted jobs.")

    # Record worker state
    with queue_manager.QueueLock():
        state = queue_manager.load_queue()
        state["worker_pid"] = os.getpid()
        state["worker_status"] = "idle"
        queue_manager.save_queue(state)

    update_notification_shade("Worker idle", "Waiting for jobs...")

    try:
        while RUNNING:
            state = queue_manager.load_queue()
            if state.get("worker_status") == "paused":
                time.sleep(poll_interval)
                continue

            job = queue_manager.get_next_pending_job()
            if job:
                acquire_wake_lock()
                job_id = job["id"]
                job_type = job.get("type", "url")
                queue_manager.mark_job_started(job_id)

                success = False
                msg = ""
                try:
                    if job_type == "url":
                        success, msg = process_url_job(job)
                    elif job_type == "file":
                        success, msg = process_file_job(job)
                    elif job_type == "batch":
                        success, msg = process_batch_job(job)
                    else:
                        success, msg = False, f"Unknown job type: {job_type}"
                except Exception as ex:
                    success, msg = False, f"Unexpected exception: {ex}"

                if success:
                    queue_manager.mark_job_completed(job_id, result_info={"summary": msg})
                else:
                    queue_manager.mark_job_failed(job_id, msg)

                release_wake_lock()
                update_notification_shade("Idle", "Queue updated")
            else:
                if single_run:
                    break
                time.sleep(poll_interval)

    finally:
        release_wake_lock()
        with queue_manager.QueueLock():
            state = queue_manager.load_queue()
            state["worker_status"] = "stopped"
            state["worker_pid"] = None
            state["current_job_id"] = None
            queue_manager.save_queue(state)
        update_notification_shade("Worker stopped", "Offline")
        log_worker("Queue worker stopped.")


if __name__ == "__main__":
    single_pass = "--once" in sys.argv
    run_worker_loop(single_run=single_pass)
