#!/bin/sh
# Produce a CONSISTENT staging copy of this host's Docker prod state, ready for the
# G8 to pull. Runs ON each source host (rpi5, rpi3), invoked over SSH by the G8's
# backup.sh just before the pull — so the work only happens when the G8 is awake.
#
# Copying a live database's volume in-flight yields a corrupt backup. This script
# quiesces per data type instead:
#   - Postgres  -> pg_dumpall to a plain .sql (crash-consistent, restorable anywhere)
#   - SQLite    -> `sqlite3 .backup` (online, consistent snapshot, no downtime)
#   - opaque volumes that MUST be file-copied -> brief `docker stop` around the copy
#   - plain file volumes/configs -> straight copy
#
# Everything lands under $STAGING_DIR; the G8 rsyncs that whole dir. Idempotent:
# the staging dir is rebuilt each run.
#
# Config is host-local (NOT in git): /etc/pi-backup/prepare.env. It declares what
# THIS host holds. See hosts/g8/README.md for per-host examples. Must be run as
# root (docker socket + reading other users' volumes) — the G8 calls it via sudo.
set -eu

CONF="${PREPARE_ENV:-/etc/pi-backup/prepare.env}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

: "${STAGING_DIR:=/var/backups/staging}"
: "${PG_CONTAINER:=}"            # e.g. "postgres"  (empty = skip Postgres)
: "${PG_SUPERUSER:=postgres}"
: "${SQLITE_VOLUMES:=}"          # "name:/abs/path/to.db ..." copied via sqlite .backup
: "${STOP_COPY_VOLUMES:=}"       # "name:/abs/src|container ..." copied under docker stop
: "${FILE_VOLUMES:=}"            # "name:/abs/src ..." straight copy (configs, provisioning)

log() { echo "[prepare-backup $(hostname) $(date '+%H:%M:%S')] $*"; }

# Rebuild staging from scratch so deleted data doesn't linger in backups.
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
chmod 0700 "$STAGING_DIR"

# --- Postgres: logical dump of ALL databases (roles + data) ------------------
if [ -n "$PG_CONTAINER" ]; then
  log "pg_dumpall from container '$PG_CONTAINER'"
  docker exec "$PG_CONTAINER" pg_dumpall -U "$PG_SUPERUSER" \
    > "$STAGING_DIR/postgres-all.sql"
  gzip -f "$STAGING_DIR/postgres-all.sql"
fi

# --- SQLite: online consistent snapshot --------------------------------------
for spec in $SQLITE_VOLUMES; do
  name="${spec%%:*}"; path="${spec#*:}"
  [ -f "$path" ] || { log "SQLite '$name': $path missing — skipping"; continue; }
  log "sqlite .backup '$name'"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$path" ".backup '$STAGING_DIR/$name.sqlite'"
  else
    # No sqlite3 on host: borrow it from the alpine image (small, cached).
    dir="$(dirname "$path")"; file="$(basename "$path")"
    docker run --rm -v "$dir:/db" nouchka/sqlite3 \
      /db/"$file" ".backup '/db/$name.sqlite.tmp'"
    mv "$dir/$name.sqlite.tmp" "$STAGING_DIR/$name.sqlite"
  fi
done

# --- Volumes that can only be file-copied: brief stop for consistency --------
for spec in $STOP_COPY_VOLUMES; do
  name="${spec%%:*}"; rest="${spec#*:}"
  src="${rest%%|*}"; cont="${rest#*|}"
  log "docker stop '$cont' -> copy '$name' -> start"
  docker stop "$cont" >/dev/null
  # trap-free: restart the container even if the copy fails
  if cp -a "$src" "$STAGING_DIR/$name"; then :; else docker start "$cont" >/dev/null; exit 1; fi
  docker start "$cont" >/dev/null
done

# --- Plain file volumes / configs --------------------------------------------
for spec in $FILE_VOLUMES; do
  name="${spec%%:*}"; src="${spec#*:}"
  [ -e "$src" ] || { log "file volume '$name': $src missing — skipping"; continue; }
  log "copy '$name'"
  cp -a "$src" "$STAGING_DIR/$name"
done

log "staging ready at $STAGING_DIR"
