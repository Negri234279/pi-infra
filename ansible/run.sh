#!/usr/bin/env bash
# Run an Ansible playbook with observability wired into the existing stack:
#
#   A) Logs   → the run's output is copied (color-stripped) into the systemd
#               journal tagged `ansible`. Alloy already ships the host journal to
#               Loki, so it lands in Grafana with no extra plumbing:
#                   {job="systemd-journal", host="rpi5", identifier="ansible"}
#   B) Marker → if Grafana credentials are present, the community.grafana
#               `grafana_annotations` callback drops a start/end annotation on the
#               dashboards (red if the run fails).
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
	# shellcheck disable=SC1091
	source .env.local
	set +a
fi

# timer + profile_tasks come from ansible.cfg; add the Grafana callback only when
# a URL is configured, so plain runs never warn about missing credentials.
if [[ -n "${GRAFANA_URL:-}" ]]; then
	export ANSIBLE_CALLBACKS_ENABLED="timer,profile_tasks,community.grafana.grafana_annotations"
	echo "→ Grafana annotations: ON ($GRAFANA_URL)"
else
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
