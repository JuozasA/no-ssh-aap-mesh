#!/usr/bin/env bash
#
# prepare-rds-postgres.sh   (merges the old prepare + fix-metrics scripts)
# ----------------------------------------------------------------------------
# Prepares an AWS RDS PostgreSQL instance for AAP 2.7 (admin-creds mode) AND
# fixes the automation-metrics read-only access in one pass:
#
#   1. Preflight   - connect as the RDS admin, assert version >= 15, TLS in use,
#                    admin can CREATE ROLE/DATABASE (rds_superuser), hstore avail.
#   2. RDS CA      - fetch the RDS CA bundle for *_pg_sslmode=verify-full.
#   3. Controller  - ensure the controller owner role + controller database
#                    exist (CREATE DATABASE ... IF missing, owned by that role).
#   4. Metrics     - ensure the read-only user exists and grant it durable
#                    SELECT on the controller DB, INCLUDING default privileges
#                    tied to the controller owner so future tables are covered.
#
# All names default to values read from the inventory file next to this script
# (controller_pg_host / _database / _username, postgresql_admin_username, etc.);
# override any with an environment variable. Idempotent - safe to re-run, and
# re-run after AAP upgrades that migrate the controller schema.
#
# Usage:
#   PG_ADMIN_PASSWORD='...' ./prepare-rds-postgres.sh
#   INVENTORY=/path/inventory PG_ADMIN_PASSWORD='...' ./prepare-rds-postgres.sh
# ----------------------------------------------------------------------------
set -euo pipefail

INVENTORY="${INVENTORY:-$(dirname "$(realpath "$0")")/inventory}"

# Pull "key=value" from the INI inventory (first match, strips quotes/comments).
inv_get() {
  [[ -f "$INVENTORY" ]] || return 0
  sed -nE "s/^[[:space:]]*$1=([^#]*)/\1/p" "$INVENTORY" | head -1 \
    | sed -E 's/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/'
}

# ---- Connection / names (env overrides inventory) --------------------------
PGHOST="${PGHOST:-$(inv_get controller_pg_host)}"
PGPORT="${PGPORT:-5432}"
PG_ADMIN_USER="${PG_ADMIN_USER:-$(inv_get postgresql_admin_username)}"
PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-$(inv_get postgresql_admin_password)}"
PG_ADMIN_DB="${PG_ADMIN_DB:-postgres}"
PGSSLMODE="${PGSSLMODE:-require}"

CONTROLLER_DB="${CONTROLLER_DB:-$(inv_get controller_pg_database)}"
CONTROLLER_OWNER="${CONTROLLER_OWNER:-$(inv_get controller_pg_username)}"
CONTROLLER_OWNER_PASSWORD="${CONTROLLER_OWNER_PASSWORD:-$(inv_get controller_pg_password)}"

READONLY_USER="${READONLY_USER:-$(inv_get automationmetrics_controller_pg_username)}"
READONLY_USER="${READONLY_USER:-ms_awx_readonly}"   # installer default
READONLY_PASSWORD="${READONLY_PASSWORD:-$(inv_get automationmetrics_controller_read_pg_password)}"

METRICS_DB="${METRICS_DB:-$(inv_get automationmetrics_pg_database)}"
METRICS_USER="${METRICS_USER:-$(inv_get automationmetrics_pg_username)}"
METRICS_PASSWORD="${METRICS_PASSWORD:-$(inv_get automationmetrics_pg_password)}"

# ---- RDS CA bundle ---------------------------------------------------------
# Use the REGIONAL bundle, not global: custom_ca_cert is concatenated into
# receptor's mesh-CA.crt (16KB QUIC limit). The global bundle (~165KB/108 certs)
# would break the mesh; the regional bundle is ~4-5KB.
FETCH_RDS_CA="${FETCH_RDS_CA:-true}"
RDS_REGION="${RDS_REGION:-eu-west-2}"
RDS_CA_URL="${RDS_CA_URL:-https://truststore.pki.rds.amazonaws.com/${RDS_REGION}/${RDS_REGION}-bundle.pem}"
RDS_CA_OUT="${RDS_CA_OUT:-$(dirname "$(realpath "$0")")/rds-${RDS_REGION}-ca.pem}"

# ---- Helpers ---------------------------------------------------------------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
sqlq() { printf "%s" "${1//\'/\'\'}"; }   # escape single quotes for SQL literals

command -v psql >/dev/null || die "psql not found (sudo dnf install -y postgresql)."
[[ -n "$PGHOST" ]]            || die "PGHOST not set and controller_pg_host not in ${INVENTORY}."
[[ -n "$PG_ADMIN_USER" ]]     || die "PG_ADMIN_USER not set and postgresql_admin_username not in inventory."
[[ -n "$PG_ADMIN_PASSWORD" ]] || die "PG_ADMIN_PASSWORD is required (RDS master password)."
[[ -n "$CONTROLLER_DB" ]]     || die "CONTROLLER_DB not set and controller_pg_database not in inventory."
[[ -n "$CONTROLLER_OWNER" ]]  || die "CONTROLLER_OWNER not set and controller_pg_username not in inventory."

export PGPASSWORD="$PG_ADMIN_PASSWORD" PGSSLMODE
# -d targets: admin maintenance DB, vs the controller DB.
adm() { psql -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PG_ADMIN_USER" -d "$PG_ADMIN_DB"  -tA -c "$1"; }
ctl() { psql -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PG_ADMIN_USER" -d "$CONTROLLER_DB" -tA -c "$1"; }

cat <<PLAN

  RDS host         : ${PGHOST}:${PGPORT}   (admin: ${PG_ADMIN_USER})
  Controller DB    : ${CONTROLLER_DB}   owner: ${CONTROLLER_OWNER}
  Metrics RO user  : ${READONLY_USER}
  Inventory        : ${INVENTORY}
PLAN

# ---- 1. Preflight ----------------------------------------------------------
ver="$(adm 'SHOW server_version;')" || die "Cannot connect to ${PGHOST} as ${PG_ADMIN_USER}. Check the security group, master creds, and PGSSLMODE."
[[ "${ver%%.*}" -ge 15 ]] || die "PostgreSQL ${ver} < 15 (AAP 2.7 requires >= 15)."
log "Connected. server_version=${ver}"

[[ "$(adm 'SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid();')" == "t" ]] \
  && log "Connection is using TLS." \
  || warn "Connection NOT using TLS (PGSSLMODE=${PGSSLMODE}). For production enforce rds.force_ssl=1 + verify-full."

is_rds_super="$(adm "SELECT pg_has_role(current_user, 'rds_superuser', 'MEMBER');" 2>/dev/null || echo f)"
read -r createrole createdb < <(adm "SELECT rolcreaterole, rolcreatedb FROM pg_roles WHERE rolname=current_user;" | tr '|' ' ')
if [[ "$is_rds_super" != "t" && ( "$createrole" != "t" || "$createdb" != "t" ) ]]; then
  die "Admin '${PG_ADMIN_USER}' is not rds_superuser and lacks CREATE ROLE/DATABASE. Use the RDS master user."
fi
log "Admin can create roles/databases (rds_superuser=${is_rds_super})."

[[ "$(adm "SELECT 1 FROM pg_available_extensions WHERE name='hstore';")" == "1" ]] \
  && log "hstore extension available." \
  || warn "hstore not available on this instance (the hub DB needs it)."

# ---- 2. RDS CA bundle ------------------------------------------------------
if [[ "$FETCH_RDS_CA" == "true" ]] && command -v curl >/dev/null; then
  curl -fsSL "$RDS_CA_URL" -o "$RDS_CA_OUT" \
    && log "Fetched RDS CA bundle -> ${RDS_CA_OUT} (use as custom_ca_cert)." \
    || warn "Could not download RDS CA bundle (continuing)."
fi

# ---- 3. Controller owner role + database -----------------------------------
if [[ "$(adm "SELECT 1 FROM pg_roles WHERE rolname='$(sqlq "$CONTROLLER_OWNER")';")" != "1" ]]; then
  if [[ -n "$CONTROLLER_OWNER_PASSWORD" ]]; then
    adm "CREATE ROLE \"${CONTROLLER_OWNER}\" LOGIN PASSWORD '$(sqlq "$CONTROLLER_OWNER_PASSWORD")';"
  else
    adm "CREATE ROLE \"${CONTROLLER_OWNER}\" LOGIN;"
    warn "Created '${CONTROLLER_OWNER}' without a password (set controller_pg_password / CONTROLLER_OWNER_PASSWORD); the installer will set it later."
  fi
  log "Created controller owner role '${CONTROLLER_OWNER}'."
else
  log "Controller owner role '${CONTROLLER_OWNER}' exists."
fi

# Admin must be a member of the owner role to create a DB owned by it and to
# manage its objects (rds_superuser is not a true superuser). Idempotent.
adm "GRANT \"${CONTROLLER_OWNER}\" TO \"${PG_ADMIN_USER}\";" >/dev/null

if [[ "$(adm "SELECT 1 FROM pg_database WHERE datname='$(sqlq "$CONTROLLER_DB")';")" != "1" ]]; then
  adm "CREATE DATABASE \"${CONTROLLER_DB}\" OWNER \"${CONTROLLER_OWNER}\";"
  log "Created controller database '${CONTROLLER_DB}' (owner ${CONTROLLER_OWNER})."
else
  log "Controller database '${CONTROLLER_DB}' exists."
fi

# ---- 3b. Metrics owner role + database (works around an installer bug) ------
# automationmetrics/tasks/postgresql.yml creates the metrics DB owned by
# metrics-user BEFORE granting that role to the admin (the controller role does
# it in the right order; metrics does not). On RDS the admin is rds_superuser,
# NOT a true superuser, so "CREATE DATABASE ... OWNER metrics-user" fails with:
#   InsufficientPrivilege: must be able to SET ROLE "metrics-user"
# Pre-granting the membership (and pre-creating the DB) makes the installer step
# succeed. Idempotent.
if [[ -n "$METRICS_USER" ]]; then
  if [[ "$(adm "SELECT 1 FROM pg_roles WHERE rolname='$(sqlq "$METRICS_USER")';")" != "1" ]]; then
    if [[ -n "$METRICS_PASSWORD" ]]; then
      adm "CREATE ROLE \"${METRICS_USER}\" LOGIN PASSWORD '$(sqlq "$METRICS_PASSWORD")';"
    else
      adm "CREATE ROLE \"${METRICS_USER}\" LOGIN;"
    fi
    log "Created metrics owner role '${METRICS_USER}'."
  else
    log "Metrics owner role '${METRICS_USER}' exists."
  fi
  # THE FIX: admin must be a member of metrics-user to create a DB owned by it.
  adm "GRANT \"${METRICS_USER}\" TO \"${PG_ADMIN_USER}\";" >/dev/null
  if [[ -n "$METRICS_DB" ]]; then
    if [[ "$(adm "SELECT 1 FROM pg_database WHERE datname='$(sqlq "$METRICS_DB")';")" != "1" ]]; then
      adm "CREATE DATABASE \"${METRICS_DB}\" OWNER \"${METRICS_USER}\";"
      log "Created metrics database '${METRICS_DB}' (owner ${METRICS_USER})."
    else
      log "Metrics database '${METRICS_DB}' exists."
    fi
  fi
fi

# ---- 4. Metrics read-only user + durable grants ----------------------------
if [[ "$(adm "SELECT 1 FROM pg_roles WHERE rolname='$(sqlq "$READONLY_USER")';")" != "1" ]]; then
  if [[ -n "$READONLY_PASSWORD" ]]; then
    adm "CREATE ROLE \"${READONLY_USER}\" LOGIN PASSWORD '$(sqlq "$READONLY_PASSWORD")';"
  else
    adm "CREATE ROLE \"${READONLY_USER}\" LOGIN;"
    warn "Created '${READONLY_USER}' without a password (set automationmetrics_controller_read_pg_password / READONLY_PASSWORD)."
  fi
  log "Created metrics read-only user '${READONLY_USER}'."
else
  log "Metrics read-only user '${READONLY_USER}' exists."
fi

log "Applying durable read-only grants on '${CONTROLLER_DB}'"
ctl "GRANT USAGE ON SCHEMA public TO \"${READONLY_USER}\";"
ctl "GRANT SELECT ON ALL TABLES    IN SCHEMA public TO \"${READONLY_USER}\";"
ctl "GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO \"${READONLY_USER}\";"
# The piece the installer omits: future tables created by the controller owner
# (migrations / upgrades) are auto-granted SELECT.
ctl "ALTER DEFAULT PRIVILEGES FOR ROLE \"${CONTROLLER_OWNER}\" IN SCHEMA public GRANT SELECT ON TABLES    TO \"${READONLY_USER}\";"
ctl "ALTER DEFAULT PRIVILEGES FOR ROLE \"${CONTROLLER_OWNER}\" IN SCHEMA public GRANT SELECT ON SEQUENCES TO \"${READONLY_USER}\";"

log "Done. RDS is prepared and metrics read-only access is durable."
echo "  Re-run after any AAP upgrade that migrates the controller schema."
[[ -f "$RDS_CA_OUT" ]] && echo "  custom_ca_cert => ${RDS_CA_OUT}"
