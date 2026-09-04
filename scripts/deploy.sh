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

# First pass fetches/pulls, then re-execs the (possibly rewritten) script so the
# deploy logic below always runs from the NEW code. The re-exec pass skips this
# block and takes OLD/NEW from the env the first pass exported.
#
# Without the re-exec, bash would keep running the version of this script it loaded
# at start against the freshly pulled tree — e.g. an old `pull` without
# --ignore-buildable choking on a locally-built service (smartctl-exporter) whose
# build guard only exists in the new script.
if [ -z "${DEPLOY_REEXEC:-}" ]; then
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

  DEPLOY_REEXEC=1 DEPLOY_OLD="$OLD" DEPLOY_NEW="$NEW" exec "$0" "$@"
fi

# Re-exec pass: the diff range was decided by the first pass, before the pull.
OLD="$DEPLOY_OLD"
NEW="$DEPLOY_NEW"

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
# smartctl-exporter is the ONLY locally-built service. Rebuilding it every deploy
# is NOT a cached no-op: its Dockerfile apt-installs smartmontools, so a
# cache-less rebuild produces a NEW image digest even for the same version — which
# spams "container updated" notifications. So only pass --build when its build
# context actually changed; otherwise reuse the existing image.
BUILD_ARG=""
if changed '^core/smartctl-exporter/'; then
  log "smartctl-exporter context changed -> rebuilding it"
  BUILD_ARG="--build"
fi
log "applying compose"
docker compose up -d --remove-orphans $BUILD_ARG

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
if changed '^core/nginx-proxy-manager/npm-custom/'; then
  # These are single-FILE bind mounts, so git replacing the file leaves the
  # container bound to the old inode — a reload wouldn't see the change. Recreate
  # the container so it re-binds the new file, then nginx starts with it.
  log "NPM custom nginx config changed -> recreate nginx-proxy-manager"
  docker compose up -d --force-recreate nginx-proxy-manager
fi
if changed '^core/nginx-proxy-manager/exporter-config'; then
  log "npm-exporter config changed -> restart npm-exporter"
  docker compose restart npm-exporter
fi
if changed '^core/blackbox/'; then
  log "blackbox config changed -> restart blackbox-exporter"
  docker compose restart blackbox-exporter
fi
if changed '^core/snmp-exporter/'; then
  # snmp.yml is a single-FILE bind mount, so a plain `restart` keeps the container
  # bound to the OLD inode (git replaces the file on pull) and reloads the stale
  # config — which is why switch config changes silently didn't take. Recreate so
  # it re-binds and reads the new snmp.yml. Prometheus needs nothing here: it only
  # passes module/auth params to the exporter, and any prometheus.yml change is
  # hot-reloaded by the '^core/prometheus/' handler above.
  log "snmp-exporter config changed -> recreate snmp-exporter"
  docker compose up -d --force-recreate snmp-exporter
fi
if changed '^core/homepage/'; then
  # homepage vigila config/ en caliente, pero un restart es determinista y barato.
  log "homepage config changed -> restart homepage"
  docker compose restart homepage
fi

log "done ($NEW)"
