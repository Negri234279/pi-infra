#!/usr/bin/env bash
# Run an Ansible playbook with observability wired into the existing stack:
#
#   A) Metrics → the local `prometheus_textfile` callback (callback_plugins/) writes per-playbook
#               run metrics (success/duration/task counts/last-run time) to the node-exporter
#               textfile collector dir, scraped by the `node` Prometheus job — a REAL datasource
#               (prometheus-infra). This is the primary, robust signal; it needs no journal
#               shipping and no Grafana creds. Dashboard: CI/CD · Ansible runs.
#   B) Logs   → the run's output is copied (color-stripped) into the systemd
#               journal tagged `ansible`. Alloy already ships the host journal to
#               Loki, so it lands in Grafana with no extra plumbing:
#                   {job="systemd-journal", host="rpi5", identifier="ansible"}
#               (Requires the current core Alloy config, which relabels the syslog
#               identifier → `identifier` label; redeploy Alloy if runs don't show.)
#   C) Marker → if Grafana credentials are present, the community.grafana
#               `grafana_annotations` callback drops a start/end annotation on the
#               dashboards (red if the run fails).
#
# One-time setup for A) on the control node (the textfile dir is root-owned; the metrics
# callback runs as the invoking user, so grant it write access once — it degrades to a
# warning, never a failed run, if it can't write):
#   sudo install -d -m 0775 -g "$(id -gn)" /var/lib/node_exporter/textfile
#
# Usage (from ~/pi-infra/ansible):
#   ./run.sh playbooks/bootstrap-pve.yml
#   ./run.sh playbooks/bootstrap-pve.yml --limit pve --check
#
# Any extra args are passed straight through to ansible-playbook.
set -euo pipefail

cd "$(dirname "$0")"

if [[ $# -eq 0 ]]; then
	echo "usage: $0 <playbook.yml> [ansible-playbook args...]" >&2
	exit 2
fi

# ── B) Grafana annotations: opt-in, driven by a gitignored .env.local ───────────
# Provide GRAFANA_URL (+ GRAFANA_API_KEY or GRAFANA_USER/GRAFANA_PASSWORD) to turn
# annotations on. Copy .env.local.example → .env.local and fill it in.
if [[ -f .env.local ]]; then
	set -a
	# Strip CRLF: .env.local is often edited on Windows, and a trailing \r ends up
	# glued to the token → Grafana rejects the Bearer header ("Invalid header value").
	# shellcheck disable=SC1091
	source <(sed 's/\r$//' .env.local)
	set +a
fi

# Base callbacks (also in ansible.cfg for direct ansible-playbook use). Setting the env var
# below OVERRIDES ansible.cfg's list, so prometheus_textfile must be repeated here or it would be
# dropped whenever the Grafana branch runs. The Grafana annotations callback is appended only when
# a URL is configured, so plain runs never warn about missing credentials.
base_callbacks="timer,profile_tasks,prometheus_textfile"
if [[ -n "${GRAFANA_URL:-}" ]]; then
	export ANSIBLE_CALLBACKS_ENABLED="${base_callbacks},community.grafana.grafana_annotations"
	echo "→ Grafana annotations: ON ($GRAFANA_URL)"
else
	export ANSIBLE_CALLBACKS_ENABLED="${base_callbacks}"
	echo "→ Grafana annotations: OFF (no GRAFANA_URL in .env.local)"
fi

# ── A) Ship the run to the journal (Alloy → Loki) while keeping color on screen ─
# ANSIBLE_FORCE_COLOR keeps the terminal copy colored even though stdout is piped;
# the journal copy is stripped of ANSI escapes so it stays clean in Loki.
export ANSIBLE_FORCE_COLOR=1

# pipefail is set, so PIPESTATUS[0] is ansible-playbook's real exit code.
ansible-playbook "$@" 2>&1 \
	| tee >(sed -r 's/\x1b\[[0-9;]*[mGKH]//g' | systemd-cat -t ansible --priority=info)

exit "${PIPESTATUS[0]}"
