#!/usr/bin/env bash
# Daily backup of the whole Pi stack into the restic repo on the NAS.
#
# Flow:
#   1. Consistent dumps of the stateful services that must NOT be copied file-by-file
#      while live (Postgres, Redis, coreforge's SQLite) → /dump.
#   2. One restic snapshot of  /dump  +  the app data volumes (/volumes/*, mounted RO)
#      +  the on-disk repo tree (/repo, holds the gitignored secrets, NPM data + TLS
#      certs, homepage/mktxp/ipmi configs, ansible vault…).
#   3. GFS retention:  forget --prune  with the keep-daily/weekly/monthly policy.
#   4. Report: node-exporter textfile metrics + a healthchecks.io ping.
#
# The observability TSDBs (Prometheus/Loki/Tempo/Alloy/Alertmanager) are deliberately
# NOT backed up — they self-regenerate and would bloat the repo. See docs/backups.md.
set -uo pipefail

# When invoked by crond the environment is minimal; entrypoint.sh persisted the
# container env here so the run has RESTIC_*, KEEP_*, HC_*, container names, etc.
[ -f /etc/backup.env ] && . /etc/backup.env

log() { echo "[backup $(date '+%Y-%m-%dT%H:%M:%S%z')] $*"; }

# ── Config (overridable via .env / compose) ─────────────────────────────────────
: "${RESTIC_REPOSITORY:?}"; : "${RESTIC_PASSWORD:?}"
KEEP_DAILY="${KEEP_DAILY:-14}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"
BACKUP_HOST="${BACKUP_HOST:-rpi5}"

PG_CONTAINER="${PG_CONTAINER:-postgres}"
PG_USER="${PG_USER:-postgres}"
REDIS_CONTAINER="${REDIS_CONTAINER:-powerlog-redis}"
COREFORGE_DB="${COREFORGE_DB:-/coreforge/coreforge.prod.db}"

TEXTFILE="${TEXTFILE_DIR:-/textfile}/backup.prom"
HC_URL="${BACKUP_HEALTHCHECK_URL:-}"        # healthchecks.io ping base (optional)

DUMP_DIR=/dump
START_TS=$(date +%s)
WARN=0   # non-fatal problems (a dump was skipped); still produce a snapshot

hc() { [ -n "$HC_URL" ] && curl -fsS -m 15 --retry 3 -o /dev/null "${HC_URL}${1:-}" || true; }

# ── Report on exit no matter how we got here ────────────────────────────────────
finish() {
  local rc=$1 end dur; end=$(date +%s); dur=$((end - START_TS))
  local repo_bytes snaps
  repo_bytes=$(restic stats --mode raw-data --json 2>/dev/null | sed -n 's/.*"total_size":\([0-9]*\).*/\1/p'); repo_bytes=${repo_bytes:-0}
  snaps=$(restic snapshots --json 2>/dev/null | grep -o '"time"' | wc -l | tr -d ' '); snaps=${snaps:-0}

  local tmp="${TEXTFILE}.$$"
  {
    echo "# HELP pi_backup_success Whether the last backup run fully succeeded (1) or not (0)."
    echo "# TYPE pi_backup_success gauge"
    echo "pi_backup_success $([ "$rc" -eq 0 ] && echo 1 || echo 0)"
    echo "# HELP pi_backup_last_duration_seconds Duration of the last backup run."
    echo "# TYPE pi_backup_last_duration_seconds gauge"
    echo "pi_backup_last_duration_seconds $dur"
    echo "# HELP pi_backup_warnings Non-fatal issues in the last run (e.g. a skipped dump)."
    echo "# TYPE pi_backup_warnings gauge"
    echo "pi_backup_warnings $WARN"
    echo "# HELP pi_backup_repo_size_bytes restic repo size (raw deduplicated data)."
    echo "# TYPE pi_backup_repo_size_bytes gauge"
    echo "pi_backup_repo_size_bytes $repo_bytes"
    echo "# HELP pi_backup_snapshots_total Number of snapshots currently in the repo."
    echo "# TYPE pi_backup_snapshots_total gauge"
    echo "pi_backup_snapshots_total $snaps"
    if [ "$rc" -eq 0 ]; then
      echo "# HELP pi_backup_last_success_timestamp_seconds Unix time of the last successful backup."
      echo "# TYPE pi_backup_last_success_timestamp_seconds gauge"
      echo "pi_backup_last_success_timestamp_seconds $end"
    fi
  } > "$tmp" 2>/dev/null && mv "$tmp" "$TEXTFILE" 2>/dev/null || log "WARN: could not write metrics to $TEXTFILE"

  if [ "$rc" -eq 0 ]; then
    log "DONE in ${dur}s (repo raw ${repo_bytes}B, ${snaps} snapshots, warnings=$WARN)"
    # A run that finished but skipped a dump pings /fail so it's visibly degraded.
    [ "$WARN" -eq 0 ] && hc "" || hc "/fail"
  else
    log "FAILED (rc=$rc) after ${dur}s"; hc "/fail"
  fi
  exit "$rc"
}
trap 'finish $?' EXIT

hc "/start"
log "starting backup → $RESTIC_REPOSITORY (host=$BACKUP_HOST)"
rm -rf "${DUMP_DIR:?}/"* 2>/dev/null || true
mkdir -p "$DUMP_DIR/postgres" "$DUMP_DIR/redis" "$DUMP_DIR/coreforge"

# ── 1a. Postgres — logical dump of the WHOLE cluster (roles + every DB) ──────────
# `docker exec` uses in-container peer auth, so no password lives here. pg_dumpall
# output restores cleanly into a fresh Postgres with `psql -f`.
if docker exec "$PG_CONTAINER" true 2>/dev/null; then
  log "pg_dumpall ($PG_CONTAINER)…"
  if docker exec "$PG_CONTAINER" pg_dumpall -U "$PG_USER" | gzip > "$DUMP_DIR/postgres/pg_dumpall.sql.gz"; then
    [ "${PIPESTATUS[0]}" -eq 0 ] || { log "WARN: pg_dumpall reported an error"; WARN=1; }
    log "  → $(du -h "$DUMP_DIR/postgres/pg_dumpall.sql.gz" | cut -f1)"
  else
    log "WARN: pg_dumpall failed"; WARN=1
  fi
else
  log "WARN: container '$PG_CONTAINER' not found — skipping Postgres dump"; WARN=1
fi

# ── 1b. Redis — flush the in-memory dataset to disk before the volume is captured ─
# powerlog's Redis is appendonly (BullMQ jobs); SAVE also refreshes the RDB so the
# /volumes/powerlog-redis-data copy is point-in-time consistent.
if docker exec "$REDIS_CONTAINER" true 2>/dev/null; then
  log "redis SAVE ($REDIS_CONTAINER)…"
  docker exec "$REDIS_CONTAINER" redis-cli SAVE >/dev/null 2>&1 || { log "WARN: redis SAVE failed"; WARN=1; }
else
  log "note: container '$REDIS_CONTAINER' not present — nothing to flush"
fi

# ── 1c. coreforge — online SQLite backup (WAL-safe; volume mounted RW at /coreforge)
# sqlite's `.backup` uses the online backup API: consistent even while coreforge
# writes, without stopping the app.
if [ -f "$COREFORGE_DB" ]; then
  log "sqlite .backup ($COREFORGE_DB)…"
  if sqlite3 "$COREFORGE_DB" ".backup '$DUMP_DIR/coreforge/coreforge.db'"; then
    log "  → $(du -h "$DUMP_DIR/coreforge/coreforge.db" | cut -f1)"
  else
    log "WARN: sqlite backup failed"; WARN=1
  fi
else
  # Fall back to any *.db in the mount so a renamed DB is still captured.
  db=$(ls /coreforge/*.db 2>/dev/null | head -1 || true)
  if [ -n "$db" ]; then
    log "sqlite .backup (found $db)…"
    sqlite3 "$db" ".backup '$DUMP_DIR/coreforge/coreforge.db'" || { log "WARN: sqlite backup failed"; WARN=1; }
  else
    log "WARN: no coreforge SQLite DB at $COREFORGE_DB — skipping"; WARN=1
  fi
fi

# ── 2. The restic snapshot ──────────────────────────────────────────────────────
# One snapshot spanning the dumps, the app data volumes (RO), and the on-disk repo
# tree (secrets + NPM data/certs). --exclude keeps git internals and caches out.
log "restic backup…"
restic backup \
  --host "$BACKUP_HOST" \
  --tag daily \
  --exclude-caches \
  --exclude "/repo/.git" \
  --exclude "*/node_modules" \
  "$DUMP_DIR" /volumes /repo
rc=$?
if [ "$rc" -ne 0 ]; then
  log "ERROR: restic backup failed (rc=$rc)"; exit "$rc"
fi

# ── 3. GFS retention — prune old restore points ─────────────────────────────────
# This is the LOGICAL retention (how many restore points live in the repo). The ZFS
# snapshots of the dataset on the NAS are a separate immutability layer (see docs).
log "restic forget --prune (d=$KEEP_DAILY w=$KEEP_WEEKLY m=$KEEP_MONTHLY)…"
restic forget --prune \
  --host "$BACKUP_HOST" \
  --keep-daily "$KEEP_DAILY" \
  --keep-weekly "$KEEP_WEEKLY" \
  --keep-monthly "$KEEP_MONTHLY" \
  || { log "WARN: forget/prune failed (snapshot is safe; retention not applied)"; WARN=1; }

# Clear the dumps so plaintext SQL/DBs don't linger on the container's disk.
rm -rf "${DUMP_DIR:?}/"* 2>/dev/null || true
exit 0
