/**
 * Termux Media Normalizer - Mobile Web App Logic
 */

const app = {
  activeTab: 'queue',
  queueFilter: 'all',
  pollTimer: null,
  isPolling: false,
  autoScrollLogs: true,
  currentStatus: null,
  allJobs: [],

  init() {
    this.bindEvents();
    this.startPolling();
    this.fetchStatus();
    this.fetchQueue();
    this.fetchConfig();
  },

  bindEvents() {
    // Navigation Tabs (Desktop & Mobile)
    document.querySelectorAll('.nav-tab, .mobile-nav-btn').forEach(btn => {
      btn.addEventListener('click', (e) => {
        const tab = btn.dataset.tab;
        this.switchTab(tab);
      });
    });

    // Queue Filter Pills
    document.querySelectorAll('.filter-pill').forEach(btn => {
      btn.addEventListener('click', (e) => {
        document.querySelectorAll('.filter-pill').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        this.queueFilter = btn.dataset.filter;
        this.renderQueue();
      });
    });

    // Quick Action: Process Now
    const btnProcess = document.getElementById('btn-quick-process');
    if (btnProcess) {
      btnProcess.addEventListener('click', () => this.triggerProcessNow());
    }

    // Worker Toggle
    const btnToggleWorker = document.getElementById('btn-toggle-worker');
    if (btnToggleWorker) {
      btnToggleWorker.addEventListener('click', () => this.toggleWorker());
    }

    // Queue Bulk Actions
    document.getElementById('btn-clear-completed')?.addEventListener('click', () => this.clearCompleted());
    document.getElementById('btn-retry-failed')?.addEventListener('click', () => this.retryAllFailed());
    document.getElementById('btn-refresh-queue')?.addEventListener('click', () => this.fetchQueue());

    // Add Media Form
    document.getElementById('btn-submit-add')?.addEventListener('click', () => this.submitAddMedia());
    document.getElementById('btn-clear-input')?.addEventListener('click', () => {
      const ta = document.getElementById('input-urls');
      if (ta) ta.value = '';
    });
    document.getElementById('btn-paste-clipboard')?.addEventListener('click', () => this.pasteFromClipboard());

    // Config Sliders & Presets
    const lufsRange = document.getElementById('config-target-lufs-range');
    const lufsBadge = document.getElementById('badge-current-lufs');
    if (lufsRange && lufsBadge) {
      lufsRange.addEventListener('input', (e) => {
        const val = parseFloat(e.target.value).toFixed(1);
        lufsBadge.textContent = `${val} LUFS`;
        this.updatePresetButtons(val);
      });
    }

    document.querySelectorAll('.preset-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const val = btn.dataset.lufs;
        if (lufsRange && lufsBadge) {
          lufsRange.value = val;
          lufsBadge.textContent = `${val} LUFS`;
          this.updatePresetButtons(val);
        }
      });
    });

    const peakRange = document.getElementById('config-max-peak-range');
    const peakBadge = document.getElementById('badge-current-peak');
    if (peakRange && peakBadge) {
      peakRange.addEventListener('input', (e) => {
        const val = parseFloat(e.target.value).toFixed(1);
        peakBadge.textContent = `${val} dBTP`;
      });
    }

    document.getElementById('btn-save-config')?.addEventListener('click', () => this.saveConfig());

    // Logs controls
    document.getElementById('btn-refresh-logs')?.addEventListener('click', () => this.fetchLogs());
    document.getElementById('btn-clear-logs')?.addEventListener('click', () => this.clearLogs());
    document.getElementById('check-autoscroll')?.addEventListener('change', (e) => {
      this.autoScrollLogs = e.target.checked;
    });
    document.getElementById('input-log-search')?.addEventListener('input', () => this.fetchLogs());

    // System Updates
    document.getElementById('btn-check-update')?.addEventListener('click', () => this.checkUpdates());
    document.getElementById('btn-run-update')?.addEventListener('click', () => this.runUpdate());

    // Notification Shade Tile Toggle
    document.getElementById('btn-toggle-notif-tile')?.addEventListener('click', () => this.toggleNotificationTile());

    // Visibility change handling
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) {
        this.stopPolling();
      } else {
        this.startPolling();
        this.fetchStatus();
        this.fetchQueue();
      }
    });
  },

  switchTab(tabName) {
    this.activeTab = tabName;

    // Update active tab buttons
    document.querySelectorAll('.nav-tab').forEach(t => {
      t.classList.toggle('active', t.dataset.tab === tabName);
      t.setAttribute('aria-selected', t.dataset.tab === tabName);
    });
    document.querySelectorAll('.mobile-nav-btn').forEach(t => {
      t.classList.toggle('active', t.dataset.tab === tabName);
    });

    // Update active section
    document.querySelectorAll('.tab-section').forEach(s => {
      s.classList.toggle('active', s.id === `section-${tabName}`);
    });

    if (tabName === 'logs') {
      this.fetchLogs();
    } else if (tabName === 'config') {
      this.fetchConfig();
    } else if (tabName === 'system') {
      this.checkUpdates();
    }
  },

  updatePresetButtons(val) {
    document.querySelectorAll('.preset-btn').forEach(btn => {
      btn.classList.toggle('active', parseFloat(btn.dataset.lufs) === parseFloat(val));
    });
  },

  startPolling() {
    if (this.isPolling) return;
    this.isPolling = true;
    this.pollTimer = setInterval(() => {
      this.fetchStatus();
      if (this.activeTab === 'queue') {
        this.fetchQueue();
      } else if (this.activeTab === 'logs') {
        this.fetchLogs();
      }
    }, 2500);
  },

  stopPolling() {
    this.isPolling = false;
    if (this.pollTimer) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
  },

  showToast(message, type = 'info') {
    const container = document.getElementById('toast-container');
    if (!container) return;
    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    const icon = type === 'success' ? '✅' : type === 'error' ? '❌' : 'ℹ️';
    toast.innerHTML = `<span>${icon}</span> <span>${this.escapeHtml(message)}</span>`;
    container.appendChild(toast);
    setTimeout(() => {
      toast.style.opacity = '0';
      toast.style.transition = 'opacity 0.3s ease';
      setTimeout(() => toast.remove(), 300);
    }, 3500);
  },

  async fetchStatus() {
    try {
      const res = await fetch('/api/status');
      const json = await res.json();
      if (json.success && json.data) {
        this.currentStatus = json.data;
        this.updateStatusUI(json.data);
      }
    } catch (e) {
      // offline / unreachable
    }
  },

  updateStatusUI(data) {
    // Worker Pill
    const pill = document.getElementById('worker-status-pill');
    const label = document.getElementById('worker-status-text');
    const status = data.worker_status || 'idle';

    if (pill && label) {
      pill.className = `status-pill status-${status}`;
      label.textContent = status.charAt(0).toUpperCase() + status.slice(1);
    }

    // Header Target LUFS
    const headerLufs = document.getElementById('header-target-lufs');
    if (headerLufs && data.config?.TARGET_LUFS) {
      headerLufs.textContent = `${data.config.TARGET_LUFS} LUFS`;
    }

    // Metric counts
    const counts = data.counts || {};
    const pending = counts.pending || 0;
    const processing = counts.processing || 0;
    const completed = counts.completed || 0;
    const failed = counts.failed || 0;
    const total = counts.total || 0;

    const elPending = document.getElementById('stat-pending');
    const elProcessing = document.getElementById('stat-processing');
    const elCompleted = document.getElementById('stat-completed');
    const elFailed = document.getElementById('stat-failed');

    if (elPending) elPending.textContent = pending;
    if (elProcessing) elProcessing.textContent = processing;
    if (elCompleted) elCompleted.textContent = completed;
    if (elFailed) elFailed.textContent = failed;

    // Tab pending badge
    const tabBadge = document.getElementById('tab-pending-count');
    if (tabBadge) tabBadge.textContent = pending;

    // Filter counts
    const cAll = document.getElementById('count-all');
    const cPending = document.getElementById('count-pending');
    const cCompleted = document.getElementById('count-completed');
    const cFailed = document.getElementById('count-failed');
    if (cAll) cAll.textContent = total;
    if (cPending) cPending.textContent = pending;
    if (cCompleted) cCompleted.textContent = completed;
    if (cFailed) cFailed.textContent = failed;

    // Worker toggle button label
    const toggleIcon = document.getElementById('worker-toggle-icon');
    const toggleLabel = document.getElementById('worker-toggle-label');
    if (toggleIcon && toggleLabel) {
      if (status === 'paused') {
        toggleIcon.textContent = '▶️';
        toggleLabel.textContent = 'Resume Worker';
      } else {
        toggleIcon.textContent = '⏸️';
        toggleLabel.textContent = 'Pause Worker';
      }
    }

    // Disk Usage
    if (data.disk && data.disk.total > 0) {
      const freeGb = (data.disk.free / (1024 ** 3)).toFixed(1);
      const totalGb = (data.disk.total / (1024 ** 3)).toFixed(1);
      const pctUsed = Math.round((data.disk.used / data.disk.total) * 100);

      const elFree = document.getElementById('disk-free-val');
      const elTotal = document.getElementById('disk-total-val');
      const elProg = document.getElementById('disk-progress-bar');
      if (elFree) elFree.textContent = `${freeGb} GB`;
      if (elTotal) elTotal.textContent = `${totalGb} GB`;
      if (elProg) elProg.style.width = `${pctUsed}%`;
    }
  },

  async fetchQueue() {
    try {
      const res = await fetch('/api/queue');
      const json = await res.json();
      if (json.success && Array.isArray(json.jobs)) {
        this.allJobs = json.jobs;
        this.renderQueue();
      }
    } catch (e) {
      // ignore network errors during polling
    }
  },

  renderQueue() {
    const container = document.getElementById('queue-items-container');
    const emptyState = document.getElementById('queue-empty-state');
    const activeBanner = document.getElementById('active-job-banner');
    const activeTitle = document.getElementById('active-job-title');

    if (!container) return;

    // Active Processing Job Banner
    const processingJob = this.allJobs.find(j => j.status === 'processing');
    if (processingJob && activeBanner && activeTitle) {
      activeBanner.classList.remove('hidden');
      activeTitle.textContent = processingJob.display_name || processingJob.payload;
    } else if (activeBanner) {
      activeBanner.classList.add('hidden');
    }

    // Filter jobs
    const filtered = this.queueFilter === 'all'
      ? this.allJobs
      : this.allJobs.filter(j => j.status === this.queueFilter);

    if (filtered.length === 0) {
      if (emptyState) emptyState.style.display = 'block';
      container.innerHTML = '';
      return;
    }

    if (emptyState) emptyState.style.display = 'none';

    container.innerHTML = filtered.map(job => {
      const isUrl = job.type === 'url';
      const typeIcon = isUrl ? '🌐' : job.type === 'batch' ? '⚡' : '📁';
      const createdStr = job.created_at ? new Date(job.created_at).toLocaleTimeString() : '';
      const isProcessing = job.status === 'processing';

      let actionsHtml = '';
      if (job.status === 'failed') {
        actionsHtml += `<button class="btn btn-secondary btn-sm" onclick="app.retryJob('${job.id}')">🔁 Retry</button>`;
      }
      if (!isProcessing) {
        actionsHtml += `<button class="btn btn-ghost btn-sm btn-icon-only" onclick="app.deleteJob('${job.id}')" title="Delete job">🗑️</button>`;
      }

      return `
        <div class="queue-item-card ${isProcessing ? 'status-processing-card' : ''}" id="queue-item-${job.id}">
          <div class="queue-item-main">
            <div class="queue-item-type-icon">${typeIcon}</div>
            <div class="queue-item-details">
              <div class="queue-item-payload" title="${this.escapeHtml(job.payload)}">
                ${this.escapeHtml(job.display_name || job.payload)}
              </div>
              <div class="queue-item-meta">
                <span class="job-status-tag ${job.status}">${job.status}</span>
                <span>Type: <strong>${job.type}</strong></span>
                ${createdStr ? `<span>Added: ${createdStr}</span>` : ''}
                ${job.retries > 0 ? `<span>Retries: ${job.retries}</span>` : ''}
              </div>
              ${job.error ? `<div class="queue-item-error">⚠️ ${this.escapeHtml(job.error)}</div>` : ''}
            </div>
          </div>
          <div class="queue-item-actions">
            ${actionsHtml}
          </div>
        </div>
      `;
    }).join('');
  },

  async submitAddMedia() {
    const input = document.getElementById('input-urls');
    if (!input || !input.value.trim()) {
      this.showToast('Please enter at least one URL or file path.', 'error');
      return;
    }

    const raw = input.value.trim();
    try {
      const res = await fetch('/api/queue/add', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ input: raw })
      });
      const json = await res.json();
      if (json.success) {
        const addedCount = json.results.filter(r => r.success && !r.duplicate).length;
        const dupCount = json.results.filter(r => r.duplicate).length;

        let msg = `Enqueued ${addedCount} item(s).`;
        if (dupCount > 0) msg += ` (${dupCount} duplicate(s) skipped)`;
        this.showToast(msg, 'success');

        input.value = '';
        this.fetchQueue();
        this.switchTab('queue');
      } else {
        this.showToast(json.error || 'Failed to add media.', 'error');
      }
    } catch (e) {
      this.showToast(`Error adding media: ${e.message}`, 'error');
    }
  },

  async pasteFromClipboard() {
    const input = document.getElementById('input-urls');
    if (!input) return;
    try {
      if (navigator.clipboard && navigator.clipboard.readText) {
        const text = await navigator.clipboard.readText();
        if (text) {
          input.value = input.value ? `${input.value}\n${text}` : text;
          this.showToast('Pasted from clipboard', 'info');
        }
      } else {
        this.showToast('Clipboard access not permitted by browser. Please paste manually.', 'error');
      }
    } catch (e) {
      this.showToast('Clipboard read failed: paste manually.', 'error');
    }
  },

  async triggerProcessNow() {
    try {
      const res = await fetch('/api/process_now', { method: 'POST' });
      const json = await res.json();
      if (json.success) {
        this.showToast('Batch processing enqueued! Running pipeline...', 'success');
        this.fetchQueue();
        this.fetchStatus();
      }
    } catch (e) {
      this.showToast(`Failed to trigger processing: ${e.message}`, 'error');
    }
  },

  async toggleWorker() {
    const current = this.currentStatus?.worker_status || 'idle';
    const action = current === 'paused' ? 'resume' : 'pause';
    try {
      const res = await fetch('/api/queue/worker', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action })
      });
      const json = await res.json();
      if (json.success) {
        this.showToast(`Worker ${action}d successfully.`, 'info');
        this.fetchStatus();
      }
    } catch (e) {
      this.showToast(`Failed to toggle worker: ${e.message}`, 'error');
    }
  },

  async retryJob(jobId) {
    try {
      const res = await fetch('/api/queue/retry', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ job_id: jobId })
      });
      const json = await res.json();
      if (json.success) {
        this.showToast(`Job ${jobId} reset to pending`, 'success');
        this.fetchQueue();
      }
    } catch (e) {
      this.showToast(`Retry failed: ${e.message}`, 'error');
    }
  },

  async retryAllFailed() {
    try {
      const res = await fetch('/api/queue/retry', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ all: true })
      });
      const json = await res.json();
      if (json.success) {
        this.showToast(json.message, 'success');
        this.fetchQueue();
      }
    } catch (e) {
      this.showToast(`Retry failed: ${e.message}`, 'error');
    }
  },

  async deleteJob(jobId) {
    try {
      const res = await fetch('/api/queue/delete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ job_id: jobId })
      });
      const json = await res.json();
      if (json.success) {
        this.showToast('Job removed from queue', 'info');
        this.fetchQueue();
      }
    } catch (e) {
      this.showToast(`Delete failed: ${e.message}`, 'error');
    }
  },

  async clearCompleted() {
    try {
      const res = await fetch('/api/queue/clear_completed', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ include_failed: false })
      });
      const json = await res.json();
      if (json.success) {
        this.showToast(json.message, 'info');
        this.fetchQueue();
      }
    } catch (e) {
      this.showToast(`Clear failed: ${e.message}`, 'error');
    }
  },

  async fetchConfig() {
    try {
      const res = await fetch('/api/config');
      const json = await res.json();
      if (json.success && json.config) {
        const c = json.config;
        const lufsVal = parseFloat(c.TARGET_LUFS || -9);
        const lufsRange = document.getElementById('config-target-lufs-range');
        const lufsBadge = document.getElementById('badge-current-lufs');
        if (lufsRange && lufsBadge) {
          lufsRange.value = lufsVal;
          lufsBadge.textContent = `${lufsVal} LUFS`;
          this.updatePresetButtons(lufsVal);
        }

        const peakVal = parseFloat(c.MAX_TRUE_PEAK || -0.5);
        const peakRange = document.getElementById('config-max-peak-range');
        const peakBadge = document.getElementById('badge-current-peak');
        if (peakRange && peakBadge) {
          peakRange.value = peakVal;
          peakBadge.textContent = `${peakVal} dBTP`;
        }

        const audioBitrate = document.getElementById('config-audio-bitrate');
        if (audioBitrate && c.AUDIO_BITRATE) audioBitrate.value = c.AUDIO_BITRATE;

        const mediaDir = document.getElementById('config-media-dir');
        if (mediaDir && c.MEDIA_DIR) mediaDir.value = c.MEDIA_DIR;

        const autoYtdlp = document.getElementById('config-auto-ytdlp');
        if (autoYtdlp) autoYtdlp.checked = c.AUTO_UPDATE_YTDLP !== 'false';
      }
    } catch (e) {
      // ignore
    }
  },

  async saveConfig() {
    const lufs = document.getElementById('config-target-lufs-range')?.value || '-9';
    const maxPeak = document.getElementById('config-max-peak-range')?.value || '-0.5';
    const bitrate = document.getElementById('config-audio-bitrate')?.value || '192k';
    const mediaDir = document.getElementById('config-media-dir')?.value || '';
    const autoYtdlp = document.getElementById('config-auto-ytdlp')?.checked ? 'true' : 'false';

    const newConfig = {
      TARGET_LUFS: lufs,
      MAX_TRUE_PEAK: maxPeak,
      AUDIO_BITRATE: bitrate,
      MEDIA_DIR: mediaDir,
      AUTO_UPDATE_YTDLP: autoYtdlp
    };

    try {
      const res = await fetch('/api/config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ config: newConfig })
      });
      const json = await res.json();
      if (json.success) {
        this.showToast('Configuration saved successfully!', 'success');
        this.fetchStatus();
      } else {
        this.showToast(json.error || 'Failed to save configuration.', 'error');
      }
    } catch (e) {
      this.showToast(`Error saving config: ${e.message}`, 'error');
    }
  },

  async fetchLogs() {
    const terminal = document.getElementById('log-terminal');
    const content = document.getElementById('log-output-content');
    const search = document.getElementById('input-log-search')?.value || '';

    try {
      const url = `/api/logs?lines=300${search ? `&filter=${encodeURIComponent(search)}` : ''}`;
      const res = await fetch(url);
      const json = await res.json();
      if (json.success && content) {
        if (json.lines.length === 0) {
          content.textContent = 'No logs matching criteria.';
        } else {
          content.textContent = json.lines.join('');
        }
        if (this.autoScrollLogs && terminal) {
          terminal.scrollTop = terminal.scrollHeight;
        }
      }
    } catch (e) {
      // ignore
    }
  },

  async clearLogs() {
    try {
      const res = await fetch('/api/logs/clear', { method: 'POST' });
      const json = await res.json();
      if (json.success) {
        this.showToast('Processor log cleared.', 'info');
        this.fetchLogs();
      }
    } catch (e) {
      this.showToast(`Error clearing log: ${e.message}`, 'error');
    }
  },

  async checkUpdates() {
    const elLocal = document.getElementById('system-local-commit');
    const elRemote = document.getElementById('system-remote-commit');
    const elMsg = document.getElementById('system-commit-msg');

    if (elLocal) elLocal.textContent = 'Checking...';
    try {
      const res = await fetch('/api/system/check_update');
      const json = await res.json();
      if (json.success) {
        if (elLocal) elLocal.textContent = json.local_commit;
        if (elRemote) elRemote.textContent = json.remote_commit;
        if (elMsg) elMsg.textContent = json.commit_msg || '--';

        if (json.has_updates) {
          this.showToast(`Updates available! Commit: ${json.remote_commit}`, 'info');
        } else {
          this.showToast('Repository is up to date.', 'success');
        }
      }
    } catch (e) {
      if (elLocal) elLocal.textContent = 'Error';
    }
  },

  async runUpdate() {
    const btn = document.getElementById('btn-run-update');
    if (btn) btn.disabled = true;
    this.showToast('Pulling latest commits from Git...', 'info');

    try {
      const res = await fetch('/api/system/update', { method: 'POST' });
      const json = await res.json();
      if (json.success) {
        this.showToast('Updated successfully! User config preserved.', 'success');
        this.checkUpdates();
      } else {
        this.showToast(`Update failed: ${json.error || 'See log for details'}`, 'error');
      }
    } catch (e) {
      this.showToast(`Update error: ${e.message}`, 'error');
    } finally {
      if (btn) btn.disabled = false;
    }
  },

  async toggleNotificationTile() {
    this.showToast('Notification shade tile updated.', 'info');
    try {
      // Call update endpoint
      await fetch('/api/queue/worker', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'start' })
      });
    } catch (e) {}
  },

  escapeHtml(text) {
    if (!text) return '';
    const map = {
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#039;'
    };
    return text.toString().replace(/[&<>"']/g, m => map[m]);
  }
};

document.addEventListener('DOMContentLoaded', () => {
  app.init();
});
