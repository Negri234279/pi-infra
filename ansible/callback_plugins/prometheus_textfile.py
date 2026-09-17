# pi-infra — Ansible run metrics → Prometheus, the same way core/backup/backup.sh does it:
# on playbook end this callback writes a node-exporter *textfile collector* .prom file, which the
# node-exporter container (core/docker-compose.yml, --collector.textfile.directory) exposes and the
# `node` Prometheus job scrapes. So Ansible run status lands in a REAL Prometheus datasource
# (prometheus-infra) — numeric, queryable, alertable — independent of journal→Loki shipping or any
# Grafana credentials. See [[ansible-runs-grafana-observability]].
#
# Enabled by name via ansible.cfg `callbacks_enabled` (and run.sh). One .prom file PER playbook
# (so runs of different playbooks don't clobber each other's last-run metrics).
from __future__ import annotations

import os
import socket
import tempfile
import time

from ansible.plugins.callback import CallbackBase

DOCUMENTATION = """
  name: prometheus_textfile
  type: aggregate
  short_description: Write per-playbook run metrics as a node-exporter textfile (.prom)
  description:
    - On playbook completion, aggregates the recap across all hosts and writes gauge metrics
      to the node-exporter textfile collector directory so Prometheus can scrape them.
  options:
    textfile_dir:
      description: Directory node-exporter reads .prom files from.
      default: /var/lib/node_exporter/textfile
      env:
        - name: ANSIBLE_PROM_TEXTFILE_DIR
"""


def _sanitize(name: str) -> str:
    """Make a playbook name safe for a filename and a Prometheus label value."""
    return "".join(c if c.isalnum() or c in ("-", "_", ".") else "_" for c in name)


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "aggregate"
    CALLBACK_NAME = "prometheus_textfile"
    CALLBACK_NEEDS_ENABLED = True

    def __init__(self):
        super().__init__()
        self.start_time = time.time()
        self.playbook_name = "unknown"
        self.controller = socket.gethostname()

    def v2_playbook_on_start(self, playbook):
        self.start_time = time.time()
        # `_file_name` is the playbook path; take its basename without extension.
        raw = os.path.splitext(os.path.basename(getattr(playbook, "_file_name", "unknown")))[0]
        self.playbook_name = _sanitize(raw) or "unknown"

    def v2_playbook_on_stats(self, stats):
        end = time.time()
        duration = max(0, int(round(end - self.start_time)))

        agg = {"ok": 0, "changed": 0, "failures": 0, "unreachable": 0, "skipped": 0}
        hosts = sorted(stats.processed.keys())
        for host in hosts:
            summary = stats.summarize(host)
            for key in agg:
                agg[key] += int(summary.get(key, 0))

        success = 1 if (agg["failures"] == 0 and agg["unreachable"] == 0) else 0

        # Common label set for every series (Prometheus escaping: backslash and double-quote).
        def esc(v: str) -> str:
            return str(v).replace("\\", "\\\\").replace('"', '\\"')

        labels = 'playbook="{}",controller="{}"'.format(esc(self.playbook_name), esc(self.controller))

        lines = []

        def metric(name, mtype, help_text, value, extra_labels=""):
            all_labels = labels + (("," + extra_labels) if extra_labels else "")
            lines.append("# HELP {} {}".format(name, help_text))
            lines.append("# TYPE {} {}".format(name, mtype))
            lines.append("{}{{{}}} {}".format(name, all_labels, value))

        metric("ansible_playbook_last_run_success", "gauge",
               "Whether the last run of this playbook fully succeeded (1) or not (0).", success)
        metric("ansible_playbook_last_run_timestamp_seconds", "gauge",
               "Unix time the last run of this playbook finished.", int(end))
        if success:
            metric("ansible_playbook_last_success_timestamp_seconds", "gauge",
                   "Unix time of the last SUCCESSFUL run of this playbook.", int(end))
        metric("ansible_playbook_duration_seconds", "gauge",
               "Wall-clock duration of the last run of this playbook.", duration)
        metric("ansible_playbook_hosts", "gauge",
               "Number of hosts processed in the last run of this playbook.", len(hosts))

        # Task tallies (summed across hosts), one series per result via a `result` label.
        lines.append("# HELP ansible_playbook_tasks Task results in the last run, summed across hosts.")
        lines.append("# TYPE ansible_playbook_tasks gauge")
        for result, value in agg.items():
            lines.append('ansible_playbook_tasks{{{},result="{}"}} {}'.format(labels, result, value))

        self._write(lines)

    def _write(self, lines):
        directory = os.environ.get("ANSIBLE_PROM_TEXTFILE_DIR", "/var/lib/node_exporter/textfile")
        dest = os.path.join(directory, "ansible_{}.prom".format(self.playbook_name))
        payload = "\n".join(lines) + "\n"
        try:
            # Atomic replace so node-exporter never reads a half-written file (same as backup.sh).
            fd, tmp = tempfile.mkstemp(dir=directory, prefix=".ansible_", suffix=".prom.tmp")
            with os.fdopen(fd, "w") as fh:
                fh.write(payload)
            os.replace(tmp, dest)
            self._display.display("→ Prometheus metrics: wrote {}".format(dest))
        except OSError as exc:
            # Never fail a deploy over metrics. If it's a permission error, the dir just needs to be
            # writable by the run.sh user (see run.sh header for the one-time chmod).
            self._display.warning("prometheus_textfile: could not write {} ({})".format(dest, exc))
