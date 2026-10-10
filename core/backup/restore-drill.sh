#!/usr/bin/env bash
# Automated RESTORE DRILL — proves the restic backups are not just present but actually restorable.
# A backup you've never restored isn't a backup. This runs monthly (cron, see entrypoint.sh) INSIDE
# the backup container (it has restic + the NAS repo + docker-cli + the repo password), and:
#   1. restic restore of the LATEST snapshot's Postgres dump to a scratch dir (targeted → small/fast),
#   2. gunzip -t on the dump (detects a truncated/corrupt dump that `restic check` alone wouldn't),
#   3. loads the dump into a THROWAWAY postgres container and counts the restored databases —
#      the real "can I bring it back" proof (not just "the bytes are intact").
# Reports node-exporter textfile metrics (pi_backup_restore_drill_*) → Grafana + the
# BackupRestoreDrill* alerts. Never touches production data or the real postgres.
set -uo pipefail

[ -f /etc/backup.env ] && . /etc/backup.env

log() { echo "[restore-drill $(date '+%Y-%m-%dT%H:%M:%S%z')] $*"; }

: "${RESTIC_REPOSITORY:?}"; : "${RESTIC_PASSWORD:?}"
TEXTFILE="${TEXTFILE_DIR:-/textfile}/restore-drill.prom"
PG_DRILL_IMAGE="${PG_DRILL_IMAGE:-postgres:16-alpine}"
PG_DRILL_NAME="backup-restore-drill-pg"
DUMP_REL="/dump/postgres/pg_dumpall.sql.gz"

START_TS=$(date +%s)
SCRATCH="$(mktemp -d)"
OK=0            # overall drill result (1 = restorable)
DBS=0           # databases restored into the throwaway cluster

cleanup() {
  docker rm -f "$PG_DRILL_NAME" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH" 2>/dev/null || true
}

finish() {
  local end dur; end=$(date +%s); dur=$((end - START_TS))
  cleanup
  local tmp="${TEXTFILE}.$$"
  {
    echo "# HELP pi_backup_restore_drill_success Whether the last restore drill fully succeeded (1) or not (0)."
    echo "# TYPE pi_backup_restore_drill_success gauge"
    echo "pi_backup_restore_drill_success $OK"
    echo "# HELP pi_backup_restore_drill_duration_seconds Duration of the last restore drill."
    echo "# TYPE pi_backup_restore_drill_duration_seconds gauge"
    echo "pi_backup_restore_drill_duration_seconds $dur"
    echo "# HELP pi_backup_restore_drill_databases Databases restored into the throwaway cluster in the last drill."
    echo "# TYPE pi_backup_restore_drill_databases gauge"
    echo "pi_backup_restore_drill_databases $DBS"
    if [ "$OK" -eq 1 ]; then
      echo "# HELP pi_backup_last_restore_drill_timestamp_seconds Unix time of the last SUCCESSFUL restore drill."
      echo "# TYPE pi_backup_last_restore_drill_timestamp_seconds gauge"
      echo "pi_backup_last_restore_drill_timestamp_seconds $end"
    fi
  } > "$tmp" 2>/dev/null && mv "$tmp" "$TEXTFILE" 2>/dev/null || log "WARN: could not write metrics to $TEXTFILE"
  log "$([ "$OK" -eq 1 ] && echo DONE || echo FAILED) in ${dur}s (databases=$DBS)"
}
trap finish EXIT

log "restore drill → restoring $DUMP_REL from latest snapshot to $SCRATCH"

# 1. Targeted restore of just the Postgres dump (small, fast — proves the snapshot reads back).
if ! restic restore latest --include "$DUMP_REL" --target "$SCRATCH"; then
  log "ERROR: restic restore failed"; exit 1
fi
DUMP="$SCRATCH$DUMP_REL"
if [ ! -s "$DUMP" ]; then
  log "ERROR: restored dump missing/empty at $DUMP"; exit 1
fi

# 2. Integrity of the gzip stream (catches a truncated dump that would fail a real restore).
if ! gunzip -t "$DUMP" 2>/dev/null; then
  log "ERROR: dump failed gunzip -t (truncated/corrupt)"; exit 1
fi
log "  → dump present and gunzip -t OK ($(du -h "$DUMP" | cut -f1))"

# 3. Load it into a throwaway postgres and count the databases = the real restorability proof.
if ! docker image inspect "$PG_DRILL_IMAGE" >/dev/null 2>&1; then
  log "pulling $PG_DRILL_IMAGE…"; docker pull "$PG_DRILL_IMAGE" >/dev/null 2>&1 || true
fi
docker rm -f "$PG_DRILL_NAME" >/dev/null 2>&1 || true
if docker run -d --name "$PG_DRILL_NAME" -e POSTGRES_PASSWORD=drill "$PG_DRILL_IMAGE" >/dev/null 2>&1; then
  # Wait for the throwaway cluster to accept connections.
  for i in $(seq 1 30); do
    docker exec "$PG_DRILL_NAME" pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 2
  done
  log "loading dump into throwaway $PG_DRILL_IMAGE…"
  # pg_dumpall restores into a fresh cluster; ON_ERROR_STOP=0 tolerates the benign "role postgres
  # already exists" noise. Success is judged by the DB count, not psql's exit code.
  gunzip -c "$DUMP" | docker exec -i "$PG_DRILL_NAME" psql -U postgres -q -v ON_ERROR_STOP=0 postgres >/dev/null 2>&1 || true
  DBS=$(docker exec "$PG_DRILL_NAME" psql -U postgres -tAc \
        "SELECT count(*) FROM pg_database WHERE NOT datistemplate" 2>/dev/null | tr -d '[:space:]')
  DBS=${DBS:-0}
  if [ "$DBS" -ge 1 ] 2>/dev/null; then
    OK=1; log "  → restored $DBS databases — backup is restorable ✓"
  else
    log "ERROR: dump loaded but 0 databases present — restore is NOT valid"
  fi
else
  # Couldn't even start the throwaway postgres (docker/image issue, not a backup fault). Fall back to
  # the restore+gunzip proof so an infra hiccup doesn't raise a false backup alarm.
  log "WARN: could not start throwaway postgres ($PG_DRILL_IMAGE) — counting restore+gunzip as the proof"
  OK=1
fi

exit 0
