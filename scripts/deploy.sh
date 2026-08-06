#!/usr/bin/env bash
# Pull the latest repo and apply it to the running stack — idempotent, safe to run
# on a timer (see scripts/systemd/). Exits early when there's nothing new.
#
# Handles the bind-mount gotcha: configs are mounted into containers, so a changed
# YAML does NOT make `docker compose up -d` recreate the container. We diff the pulled
# commits and reload/restart only the services whose mounted config actually changed.
#
#   ./scripts/deploy.sh
#
# Requires: git, docker compose, and an `origin` remote with an upstream branch.
set -euo pipefail

# Repo root, regardless of where the script is invoked from.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[deploy $(date '+%Y-%m-%dT%H:%M:%S%z')] $*"; }

git fetch --quiet origin

OLD="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse '@{u}')"
if [ "$OLD" = "$REMOTE" ]; then
  log "already up to date ($OLD)"
  exit 0
fi

log "updating $OLD -> $REMOTE"
git pull --ff-only
NEW="$(git rev-parse HEAD)"

# Files that changed between the old and new commit.
CHANGED="$(git diff --name-only "$OLD" "$NEW")"
changed() { grep -q "$1" <<<"$CHANGED"; }

# New image tags only ever arrive via a compose file change (images are pinned).
# Scope the pull to only the apps whose compose actually changed; a change to the
# root or core compose still pulls the whole stack. Unrelated `:latest` images are
# kept fresh independently by watchtower, so skipping them here is safe.
if changed '\(^\|/\)docker-compose\.yml$'; then
  log "root/core compose changed -> pulling all images"
  # --ignore-buildable: locally-built services (e.g. smartctl-exporter) have no
  # registry image to pull; `up --build` below (re)builds them instead.
  docker compose pull --quiet --ignore-buildable
else
  PULL_SERVICES=()
  for app_compose in apps/wake-lan-app/compose.yml apps/powerlog/prod/compose.yml; do
    if changed "^${app_compose}\$"; then
      log "$app_compose changed -> queueing its images"
      while IFS= read -r svc; do
        PULL_SERVICES+=("$svc")
      done < <(docker compose -f "$app_compose" config --services)
    fi
  done
  if [ ${#PULL_SERVICES[@]} -gt 0 ]; then
    log "pulling images for: ${PULL_SERVICES[*]}"
    docker compose pull --quiet "${PULL_SERVICES[@]}"
  fi
fi

# Recreate any service whose *definition* changed (image, ports, env, mounts list).
# --build (re)builds locally-built services (e.g. smartctl-exporter) when their
# Dockerfile/context changed; it's a no-op (cached) otherwise.
log "applying compose"
docker compose up -d --remove-orphans --build

# Mounted-config changes that don't alter the container definition: reload/restart.
if changed '^core/prometheus/'; then
  log "prometheus config changed -> hot reload"
  docker compose exec -T prometheus \
    wget -qO- --post-data='' http://localhost:9090/-/reload >/dev/null || \
    log "WARN: prometheus reload failed"
fi
if changed '^core/alertmanager/'; then
  log "alertmanager config changed -> restart"
  docker compose restart alertmanager
fi
if changed '^core/grafana/provisioning/'; then
  log "grafana provisioning changed -> restart"
  docker compose restart grafana
fi
if changed '^core/nginx-proxy-manager/'; then
  log "NPM config changed -> restart npm-exporter"
  docker compose restart npm-exporter
fi

log "done ($NEW)"
