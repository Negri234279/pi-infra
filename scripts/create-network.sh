#!/usr/bin/env bash
# Creates the shared external networks if they don't exist yet:
#   - monitoring : Grafana ↔ each app's Prometheus/Loki/Tempo
#   - db         : the shared Postgres/PgBouncer ↔ each app
# Idempotent: safe to run multiple times. Run this before `docker compose up`,
# and make sure each app's compose joins these external networks.
set -euo pipefail

for NETWORK in monitoring db; do
  if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    echo "Network '$NETWORK' already exists."
  else
    docker network create "$NETWORK"
    echo "Created network '$NETWORK'."
  fi
done
