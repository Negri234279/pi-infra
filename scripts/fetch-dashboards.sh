#!/usr/bin/env bash
# Downloads the community infra dashboards from grafana.com into
# core/grafana/dashboards/ and wires them to the `Infra` datasource so they work
# the moment Grafana provisions them. Re-run to update.
#
#   ./scripts/fetch-dashboards.sh
#
# Requires: curl. (No jq needed.)
set -euo pipefail

# Resolve repo root regardless of where the script is called from.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/core/grafana/dashboards"
mkdir -p "$OUT"

# Datasource UID these dashboards should point at (matches datasources.yml).
DS_UID="prometheus-infra"

# id|revision|filename  — revision pinned for reproducibility; bump when needed.
DASHBOARDS=(
  "1860|37|node-exporter-full.json"      # Node Exporter Full (host)
  "14282|1|cadvisor.json"                # Cadvisor exporter (containers)
  "25257|1|nginx-proxy-manager.json"     # nginxlog-exporter (NPM reverse proxy)
)

fetch() {
  local id="$1" rev="$2" file="$3"
  local url="https://grafana.com/api/dashboards/${id}/revisions/${rev}/download"
  echo "↓ ${file}  (grafana.com/${id} rev ${rev})"
  # Substitute the dashboard's datasource input placeholder (any ${DS_...} name)
  # with our UID so the provisioned dashboard binds to Infra without manual input.
  curl -fsSL "$url" \
    | sed -E 's/\$\{DS_[A-Za-z0-9_-]+\}/'"${DS_UID}"'/g' \
    > "$OUT/${file}"
}

for entry in "${DASHBOARDS[@]}"; do
  IFS="|" read -r id rev file <<<"$entry"
  fetch "$id" "$rev" "$file"
done

echo "Done. ${#DASHBOARDS[@]} dashboard(s) written to core/grafana/dashboards/."
