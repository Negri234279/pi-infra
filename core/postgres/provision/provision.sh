#!/bin/sh
# Idempotent provisioner for the SHARED Postgres. Runs on every `up` (one-shot).
# Connects as superuser and ensures, without ever destroying data:
#   1. the PgBouncer auth backend (pgbouncer_auth role + SECURITY DEFINER
#      function used by auth_query — so new apps need ZERO PgBouncer config);
#   2. the postgres-exporter monitoring role (pg_monitor);
#   3. per-app role + database + grants, declared in apps/*/postgres/provision.env
#      (APP_DB / APP_DB_USER / APP_DB_PASSWORD — operator-set, the single source
#      of truth shared with the app's DATABASE_URL).
#
# Passwords are interpolated into SQL via shell heredocs: keep them alphanumeric
# (avoid $, `, ', " and spaces) to stay safe.
set -eu

: "${POSTGRES_HOST:=postgres}"
: "${POSTGRES_SUPERUSER:=postgres}"
export PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD"
PSQL="psql -v ON_ERROR_STOP=1 -h $POSTGRES_HOST -p 5432 -U $POSTGRES_SUPERUSER"

echo "[provision] waiting for postgres at $POSTGRES_HOST…"
until pg_isready -h "$POSTGRES_HOST" -U "$POSTGRES_SUPERUSER" >/dev/null 2>&1; do
  sleep 1
done

# ── 1. PgBouncer auth backend (lives in the 'postgres' maintenance db; the
#       function reads cluster-global pg_shadow, so one copy serves every app) ──
echo "[provision] ensuring PgBouncer auth backend…"
$PSQL -d postgres <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pgbouncer_auth') THEN
    CREATE ROLE pgbouncer_auth LOGIN PASSWORD '${PGBOUNCER_AUTH_PASSWORD}';
  ELSE
    ALTER ROLE pgbouncer_auth WITH PASSWORD '${PGBOUNCER_AUTH_PASSWORD}';
  END IF;
END \$\$;

CREATE SCHEMA IF NOT EXISTS pgbouncer;

CREATE OR REPLACE FUNCTION pgbouncer.get_auth(p_usename text)
  RETURNS TABLE(p_user text, p_password text)
  LANGUAGE sql SECURITY DEFINER
  SET search_path = pg_catalog AS \$func\$
    SELECT usename::text, passwd::text FROM pg_catalog.pg_shadow WHERE usename = p_usename;
  \$func\$;

REVOKE ALL ON FUNCTION pgbouncer.get_auth(text) FROM PUBLIC;
GRANT USAGE ON SCHEMA pgbouncer TO pgbouncer_auth;
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(text) TO pgbouncer_auth;
SQL

# ── 2. postgres-exporter monitoring role (least-privilege, cluster-wide) ──
echo "[provision] ensuring exporter role '${PG_EXPORTER_USER}'…"
$PSQL -d postgres <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PG_EXPORTER_USER}') THEN
    CREATE ROLE "${PG_EXPORTER_USER}" LOGIN PASSWORD '${PG_EXPORTER_PASSWORD}';
  ELSE
    ALTER ROLE "${PG_EXPORTER_USER}" WITH PASSWORD '${PG_EXPORTER_PASSWORD}';
  END IF;
END \$\$;
GRANT pg_monitor TO "${PG_EXPORTER_USER}";

-- Lock the maintenance db: app roles must not connect here (no app data lives in
-- 'postgres', but this keeps roles to their own database). Only the pooler auth
-- role (auth_dbname=postgres) and the exporter (auto-discover starts here) need it.
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
GRANT CONNECT ON DATABASE postgres TO pgbouncer_auth;
GRANT CONNECT ON DATABASE postgres TO "${PG_EXPORTER_USER}";
SQL

# ── 3. Per-app role + database + grants ──
found_app=0
for f in /apps/*/postgres/provision.env; do
  [ -f "$f" ] || continue
  found_app=1
  APP_DB=''
  APP_DB_USER=''
  APP_DB_PASSWORD=''
  # shellcheck disable=SC1090
  . "$f"
  if [ -z "$APP_DB" ] || [ -z "$APP_DB_USER" ] || [ -z "$APP_DB_PASSWORD" ]; then
    echo "[provision] skip $f (APP_DB / APP_DB_USER / APP_DB_PASSWORD missing)"
    continue
  fi

  echo "[provision] ensuring db='$APP_DB' user='$APP_DB_USER'"

  # role (create or sync password)
  $PSQL -d postgres <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${APP_DB_USER}') THEN
    CREATE ROLE "${APP_DB_USER}" LOGIN PASSWORD '${APP_DB_PASSWORD}';
  ELSE
    ALTER ROLE "${APP_DB_USER}" WITH PASSWORD '${APP_DB_PASSWORD}';
  END IF;
END \$\$;
SQL

  # database (CREATE DATABASE can't run inside a transaction/DO block)
  if ! $PSQL -tAc "SELECT 1 FROM pg_database WHERE datname = '${APP_DB}'" -d postgres | grep -q 1; then
    $PSQL -d postgres -c "CREATE DATABASE \"${APP_DB}\" OWNER \"${APP_DB_USER}\""
  fi

  # privileges + lockdown (run inside the app db)
  $PSQL -d "${APP_DB}" <<SQL
ALTER DATABASE "${APP_DB}" OWNER TO "${APP_DB_USER}";
-- Isolation: only this app's role (and the exporter) may connect.
REVOKE CONNECT ON DATABASE "${APP_DB}" FROM PUBLIC;
GRANT ALL PRIVILEGES ON DATABASE "${APP_DB}" TO "${APP_DB_USER}";
GRANT CONNECT ON DATABASE "${APP_DB}" TO "${PG_EXPORTER_USER}";
-- PG15+: public schema is locked down by default; the app owns its schema.
GRANT ALL ON SCHEMA public TO "${APP_DB_USER}";
ALTER SCHEMA public OWNER TO "${APP_DB_USER}";
SQL
done

[ "$found_app" -eq 1 ] || echo "[provision] no apps/*/postgres/provision.env found (nothing app-specific to do)"
echo "[provision] done."
