#!/usr/bin/env bash
# Creates the shared `monitoring` network if it doesn't exist yet.
# Idempotent: safe to run multiple times. Run this before `docker compose up`,
# and make sure each app's compose joins the same external network.
set -euo pipefail

NETWORK="monitoring"

if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "Network '$NETWORK' already exists."
else
  docker network create "$NETWORK"
  echo "Created network '$NETWORK'."
fi
