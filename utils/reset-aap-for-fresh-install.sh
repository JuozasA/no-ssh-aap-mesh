#!/usr/bin/env bash
#
# reset-aap-for-fresh-install.sh
# ----------------------------------------------------------------------------
# Returns an AAP 2.7 containerized environment to a clean slate for a fresh
# install. TWO independent jobs - run the one(s) you need:
#
#   rds   Drop the AAP databases + roles on the external RDS instance. The
#         uninstall playbook does NOT do this for an external DB (its database
#         play only targets the in-inventory `database` group, which is empty
#         when you use RDS), so the old DBs/roles survive and a fresh install
#         collides with them. Run ONCE from any host that can reach RDS.
#
#   host  Remove the host-side leftovers the uninstall playbook leaves behind
#         (the ~/aap base dir, podman containers/volumes/secrets/images, the
#         AAP systemd user units, ~/.config/containers). Run ON EACH AAP node
#         as the service user (e.g. ec2-user), AFTER the uninstall playbook.
#
#   host-all [inventory]
#         Run the `host` cleanup on EVERY control-plane node in the inventory,
#         from one place: Ansible resolves the control-plane groups and pushes
#         this script to each host (ansible -m script). Mesh/execution nodes are
#         excluded - clean those with clean-exec-node.sh. Defaults to the
#         inventory shipped next to this script; override via arg or INVENTORY=.
#
#   all   Do both rds + local host (only meaningful on a host that reaches RDS).
#
# >>> DESTRUCTIVE. This deletes databases and files irreversibly. <<<
# Safety: prints the plan and refuses to act unless you confirm. Either type
# the confirmation phrase when prompted, or pass FORCE=yes for automation.
#
# Usage:
#   PGHOST=db.xxxx.rds.amazonaws.com PG_ADMIN_USER=postgres PG_ADMIN_PASSWORD='...' \
#     ./reset-aap-for-fresh-install.sh rds
#   ./reset-aap-for-fresh-install.sh host
#   ... rds  (FORCE=yes to skip the prompt)
# ----------------------------------------------------------------------------
set -euo pipefail

# ---- RDS objects to drop (verify against your inventory!) ------------------
# Databases:  gateway / controller / hub / eda / eda-persistence / metrics
PG_DATABASES=(${PG_DATABASES:-gw-db ctrl-db hub-db eda eda_event_persistence metrics})
# Roles:      *_pg_username for each component + the metrics read-only user
PG_ROLES=(${PG_ROLES:-postgres-gw postgres-ctrl postgres-hub eda eda_event_stream eda_event_persistence metrics-user ms_awx_readonly})

# ---- RDS connection --------------------------------------------------------
PGHOST="${PGHOST:-}"
PGPORT="${PGPORT:-5432}"
PG_ADMIN_USER="${PG_ADMIN_USER:-postgres}"          # RDS master / postgresql_admin_username
PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-}"
PG_ADMIN_DB="${PG_ADMIN_DB:-postgres}"              # maintenance DB (never dropped)
PGSSLMODE="${PGSSLMODE:-require}"

# ---- host cleanup knobs ----------------------------------------------------
AAP_DIR="${AAP_DIR:-$HOME/aap}"
REMOVE_IMAGES="${REMOVE_IMAGES:-true}"              # also wipe pulled container images
DISABLE_LINGER="${DISABLE_LINGER:-false}"           # turn off systemd linger for the user

# ---- host-all (loop over inventory control-plane nodes) --------------------
# Default inventory = the one shipped next to this script. Override with
# INVENTORY=... or pass the path as the 2nd arg to host-all.
INVENTORY="${INVENTORY:-$(dirname "$(realpath "$0")")/inventory}"
# Groups treated as the control plane. execution_nodes are NOT here - clean
# those with clean-exec-node.sh on each mesh node.
CONTROL_PLANE_GROUPS="${CONTROL_PLANE_GROUPS:-automationcontroller:automationgateway:automationhub:automationeda:automationmetrics:ansiblelightspeed:ansiblemcp:redis}"

# ---- helpers ---------------------------------------------------------------
log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
  local phrase="$1"
  if [[ "${FORCE:-}" == "yes" ]]; then warn "FORCE=yes - skipping confirmation."; return 0; fi
  printf '\033[1;31mType "%s" to proceed: \033[0m' "$phrase"
  read -r reply
  [[ "$reply" == "$phrase" ]] || die "Confirmation failed - aborting."
}

# ============================================================================
# RDS WIPE
# ============================================================================
wipe_rds() {
  [[ -n "$PGHOST" ]]            || die "PGHOST is required for the rds job."
  [[ -n "$PG_ADMIN_PASSWORD" ]] || die "PG_ADMIN_PASSWORD is required for the rds job."
  command -v psql >/dev/null    || die "psql not found (sudo dnf install -y postgresql)."
  export PGPASSWORD="$PG_ADMIN_PASSWORD" PGSSLMODE
  local PSQL=(psql -v ON_ERROR_STOP=1 -h "$PGHOST" -p "$PGPORT" -U "$PG_ADMIN_USER" -d "$PG_ADMIN_DB" -tA)

  "${PSQL[@]}" -c 'SELECT 1' >/dev/null || die "Cannot connect to ${PGHOST} as ${PG_ADMIN_USER}."

  cat <<PLAN

  RDS target : ${PGHOST}:${PGPORT}  (admin: ${PG_ADMIN_USER})
  DROP DATABASE : ${PG_DATABASES[*]}
  DROP ROLE     : ${PG_ROLES[*]}
  (maintenance DB '${PG_ADMIN_DB}' and the admin role are NOT touched)
PLAN
  confirm "WIPE ${PGHOST}"

  # Databases first (frees role->db ownership). WITH (FORCE) terminates active
  # backends, supported on PostgreSQL >= 13 / RDS PG15.
  for db in "${PG_DATABASES[@]}"; do
    [[ "$db" == "$PG_ADMIN_DB" || "$db" == "postgres" || "$db" == template* ]] && { warn "refusing to drop '$db'"; continue; }
    log "DROP DATABASE $db"
    "${PSQL[@]}" -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE);" \
      || warn "could not drop database '$db' (continuing)"
  done

  # Roles next. DROP OWNED clears any residual privileges/default-privs in the
  # maintenance DB before dropping the role itself.
  for role in "${PG_ROLES[@]}"; do
    case "$role" in postgres|"$PG_ADMIN_USER"|rds_superuser|rds_*|pg_*) warn "refusing to drop role '$role'"; continue;; esac
    log "DROP ROLE $role"
    "${PSQL[@]}" -c "DROP OWNED BY \"$role\" CASCADE;" >/dev/null 2>&1 || true
    "${PSQL[@]}" -c "DROP ROLE IF EXISTS \"$role\";" \
      || warn "could not drop role '$role' (still owns objects in another DB? continuing)"
  done

  log "RDS wipe complete. Verify:"
  "${PSQL[@]}" -c "SELECT datname FROM pg_database WHERE datname = ANY (ARRAY['${PG_DATABASES[*]// /','}']);" || true
  "${PSQL[@]}" -c "SELECT rolname FROM pg_roles    WHERE rolname = ANY (ARRAY['${PG_ROLES[*]// /','}']);"     || true
}

# ============================================================================
# HOST CLEANUP  (run as the AAP service user on each node)
# ============================================================================
clean_host() {
  command -v podman >/dev/null || die "podman not found - run this on an AAP node as the service user."
  [[ $EUID -ne 0 ]] || warn "Running as root - rootless AAP data lives under a user account; make sure that's intended."
  # Make `systemctl --user` and rootless podman work even over a non-login SSH
  # session (e.g. when pushed by `host-all` via ansible -m script).
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

  cat <<PLAN

  Host       : $(hostname)   user: $(id -un)
  Will remove: all podman containers, volumes, secrets$( [[ "$REMOVE_IMAGES" == "true" ]] && echo ", images" )
               ${AAP_DIR}
               ~/.config/containers and AAP systemd user units
PLAN
  confirm "CLEAN $(hostname)"

  # Stop the podman socket so nothing respawns mid-clean.
  systemctl --user stop podman.socket 2>/dev/null || true
  systemctl --user disable podman.socket 2>/dev/null || true

  # Remove containers / volumes / secrets from the DEFAULT rootless store.
  log "Removing podman containers, volumes, secrets (default store)"
  podman rm -f -a 2>/dev/null || true
  podman volume rm -f -a 2>/dev/null || true
  podman secret ls -q 2>/dev/null | xargs -r -n1 podman secret rm 2>/dev/null || true
  podman system reset -f 2>/dev/null || true

  # Same for the AAP execution-plane store (custom storage.conf), if present.
  if [[ -f "${AAP_DIR}/containers/storage.conf" ]]; then
    log "Resetting AAP execution-plane podman store"
    CONTAINERS_STORAGE_CONF="${AAP_DIR}/containers/storage.conf" podman system reset -f 2>/dev/null || true
  fi

  [[ "$REMOVE_IMAGES" == "true" ]] && { log "Removing any remaining images"; podman rmi -f -a 2>/dev/null || true; }

  # AAP systemd user units (services generated by the installer).
  log "Removing AAP systemd user units"
  local ud="$HOME/.config/systemd/user"
  if [[ -d "$ud" ]]; then
    find "$ud" -maxdepth 1 -type f \
      \( -name 'receptor*.service' -o -name 'automation-*' -o -name 'postgresql*.service' \
         -o -name 'redis*.service' -o -name 'pulp*' -o -name 'eda*' -o -name 'gateway*' \) \
      -print -delete 2>/dev/null || true
    rm -rf "$ud/podman.service.d" 2>/dev/null || true
  fi
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user reset-failed 2>/dev/null || true

  # Files / directories.
  log "Removing ${AAP_DIR} and container config"
  rm -rf "${AAP_DIR}" 2>/dev/null || true
  rm -rf "$HOME/.config/containers" 2>/dev/null || true
  rm -rf "/run/user/$(id -u)/podman" 2>/dev/null || true

  if [[ "$DISABLE_LINGER" == "true" ]]; then
    log "Disabling systemd linger for $(id -un)"
    loginctl disable-linger "$(id -un)" 2>/dev/null || sudo loginctl disable-linger "$(id -un)" 2>/dev/null || true
  fi

  log "Host cleanup complete on $(hostname)."
}

# ============================================================================
# HOST-ALL  (loop the cleanup over every control-plane node in the inventory)
# ============================================================================
# Uses Ansible to (1) resolve the control-plane groups from the inventory and
# (2) push THIS script to each host and run its `host` job there, as the
# inventory's ansible_user. No sudo is needed for the host cleanup, so plain
# `-m script` (no --become) is enough. Mesh nodes are excluded by design.
clean_host_all() {
  command -v ansible >/dev/null || die "ansible not found - needed to loop over the inventory."
  [[ -f "$INVENTORY" ]] || die "Inventory not found: ${INVENTORY} (set INVENTORY=... or pass it as the 2nd arg)."

  local hosts
  hosts="$(ansible "$CONTROL_PLANE_GROUPS" -i "$INVENTORY" --list-hosts 2>/dev/null | sed '1d;s/^[[:space:]]*//' | grep -v '^[[:space:]]*$' || true)"
  [[ -n "$hosts" ]] || die "No hosts matched '${CONTROL_PLANE_GROUPS}' in ${INVENTORY}."

  printf '\n  Inventory : %s\n  Groups    : %s\n  Target hosts:\n' "$INVENTORY" "$CONTROL_PLANE_GROUPS"
  echo "$hosts" | sed 's/^/    - /'
  warn "This wipes the AAP host footprint on EVERY host above."
  confirm "CLEAN ALL"

  log "Pushing host cleanup to each control-plane node via ansible -m script"
  # `host --force` runs non-interactively on the remote (no per-node prompt).
  ansible "$CONTROL_PLANE_GROUPS" -i "$INVENTORY" -m script \
    -a "$(realpath "$0") host --force"
}

# ---- dispatch --------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
  rds)  wipe_rds ;;
  host)
    [[ "${1:-}" == "--force" || "${1:-}" == "-y" ]] && FORCE=yes
    clean_host ;;
  host-all)
    [[ -n "${1:-}" ]] && INVENTORY="$1"      # optional inventory path override
    clean_host_all ;;
  all)  wipe_rds; clean_host ;;
  *)    die "Usage: $0 {rds|host|host-all [inventory]|all}   (FORCE=yes skips prompts)" ;;
esac
