#!/usr/bin/env bash
# Keep the `backup` container alive across NAS outages.
#
# The container mounts the NAS restic repo as a docker `local` NFS volume, which
# docker mounts at container-CREATE time with `hard`. When the NAS is unreachable
# right then (it reboots, or powers off for a while), that mount fails, the
# container exits 255, and docker's restart policy does NOT retry a create-time
# mount failure — so it stays dead until someone runs `docker start` by hand.
# That is exactly what happened 2026-09-18 → 2026-09-21: the rpi5 rebooted while
# the NAS was off, the mount failed with "no route to host", and three nightly
# backups were silently missed. See docs/backups.md.
#
# This guard, run every few minutes by backup-guard.timer, brings the container
# back the moment the NAS is reachable again: `docker start` re-attempts the NFS
# mount; on an already-running container it is a harmless no-op. It also publishes
# `pi_backup_container_running` as a node-exporter textfile metric so a down
# container is visible in Grafana/Alertmanager within minutes, instead of only via
# the 26h-stale BackupTooOld.
set -euo pipefail

NAME="${BACKUP_CONTAINER:-backup}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile}"
METRIC_FILE="$TEXTFILE_DIR/backup_container.prom"

log() { echo "[backup-guard $(date '+%Y-%m-%dT%H:%M:%S%z')] $*"; }

# Publish pi_backup_container_running {1,0} atomically (write-then-rename so
# node-exporter never reads a half-written file).
write_metric() {  # $1 = 1|0
  [ -d "$TEXTFILE_DIR" ] || return 0
  local tmp
  tmp="$(mktemp "$METRIC_FILE.XXXXXX")"
  {
    echo "# HELP pi_backup_container_running Whether the restic backup container is running (1) or not (0)."
    echo "# TYPE pi_backup_container_running gauge"
    echo "pi_backup_container_running{name=\"$NAME\"} $1"
  } > "$tmp"
  mv -f "$tmp" "$METRIC_FILE"
}

state="$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo missing)"

case "$state" in
  running)
    write_metric 1
    ;;
  missing)
    log "container '$NAME' does not exist — nothing to guard (deploy the core stack first)"
    write_metric 0
    ;;
  *)
    log "container '$NAME' is '$state'; attempting start (re-mounts the NAS NFS repo)"
    if docker start "$NAME" >/dev/null 2>&1; then
      log "started '$NAME'"
      write_metric 1
    else
      log "start failed — NAS still unreachable? will retry next tick"
      write_metric 0
    fi
    ;;
esac
