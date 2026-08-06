#!/usr/bin/env bash
# Deploy a per-host agent stack (hosts/<host>/) from this repo. Run ON that host
# (e.g. the rpi3), typically from a systemd timer — see scripts/systemd/.
#
# Unlike scripts/deploy.sh (the rpi5 hub), this is scoped to ONE host directory
# and its own compose project, with no hub reload logic (no Prometheus/Grafana
# on a satellite host). Idempotent: exits early when there's nothing new.
#
#   ./scripts/deploy-host.sh rpi3
#
# Requires: git, docker compose, and an `origin` remote with an upstream branch.
set -euo pipefail

HOST="${1:?usage: deploy-host.sh <host>   (dir hosts/<host>/ must exist)}"

# Repo root, regardless of where the script is invoked from.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

COMPOSE="hosts/${HOST}/docker-compose.yml"
[ -f "$COMPOSE" ] || { echo "no such host stack: $COMPOSE" >&2; exit 1; }

log() { echo "[deploy-host:$HOST $(date '+%Y-%m-%dT%H:%M:%S%z')] $*"; }

git fetch --quiet origin
OLD="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse '@{u}')"
if [ "$OLD" = "$REMOTE" ]; then
  log "already up to date ($OLD)"
  exit 0
fi

log "updating $OLD -> $REMOTE"
git pull --ff-only

# Project name = host, so this stack is isolated from anything else on the box.
log "applying $COMPOSE (project=$HOST)"
docker compose -f "$COMPOSE" -p "$HOST" pull --quiet --ignore-buildable
docker compose -f "$COMPOSE" -p "$HOST" up -d --remove-orphans

log "done ($(git rev-parse HEAD))"
