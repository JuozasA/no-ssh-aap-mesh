#!/usr/bin/env bash
#
# clean-exec-node.sh
# ----------------------------------------------------------------------------
# Returns a hop or execution node to a clean slate so it can take a FRESH
# receptor bundle (generate-exec-node-bundle.yml -> install-exec-node.yml).
#
# These mesh nodes are installed out-of-band, so the main uninstall playbook
# never reaches them. This script reverses everything install-exec-node.yml
# does, mirroring roles/receptor/tasks/uninstall.yml plus the host-tuning and
# firewall bits the bundle installer adds:
#   - receptor systemd user service + container + named volumes
#   - receptor image and EE images (default store AND the custom aap store)
#   - ~/aap (tls, receptor/etc, controller/data, containers) and ~/.config/containers
#   - host tuning files (/etc/sysctl.d/99-aap.conf, /etc/security/limits.d/99-aap-limits.conf)
#   - the receptor firewalld port
#
# It intentionally LEAVES installed packages (podman, crun, ...) and the
# subuid/subgid ranges - the bundle installer re-ensures those and they do no
# harm to a fresh install.
#
# Run ON each hop/execution node, as the service user that ran the bundle
# (e.g. ec2-user). System-level steps use sudo.
#
#   ./clean-exec-node.sh                 # prompts for confirmation
#   FORCE=yes ./clean-exec-node.sh       # no prompt (automation)
#
# >>> DESTRUCTIVE: deletes the receptor install and its data on THIS node. <<<
# ----------------------------------------------------------------------------
set -euo pipefail

AAP_DIR="${AAP_DIR:-$HOME/aap}"
RECEPTOR_PORT="${RECEPTOR_PORT:-27199}"
RECEPTOR_PROTOCOL="${RECEPTOR_PROTOCOL:-tcp}"
RECEPTOR_FIREWALL_ZONE="${RECEPTOR_FIREWALL_ZONE:-public}"
REMOVE_IMAGES="${REMOVE_IMAGES:-true}"
REMOVE_HOST_TUNING="${REMOVE_HOST_TUNING:-true}"   # needs sudo
CLOSE_FIREWALL="${CLOSE_FIREWALL:-true}"           # needs sudo
DISABLE_LINGER="${DISABLE_LINGER:-false}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

command -v podman >/dev/null || die "podman not found - run this on the mesh node as the service user."
[[ $EUID -ne 0 ]] || warn "Running as root; rootless receptor data lives under a user account - make sure that's intended."

cat <<PLAN

  Node       : $(hostname)   user: $(id -un)
  Will remove: receptor service + container + named volumes
               $( [[ "$REMOVE_IMAGES" == "true" ]] && echo "receptor + EE images, " )${AAP_DIR}, ~/.config/containers
               $( [[ "$REMOVE_HOST_TUNING" == "true" ]] && echo "host-tuning sysctl/limits files (sudo)" )
               $( [[ "$CLOSE_FIREWALL" == "true" ]] && echo "firewalld ${RECEPTOR_PORT}/${RECEPTOR_PROTOCOL} (sudo)" )
PLAN
if [[ "${FORCE:-}" != "yes" ]]; then
  printf '\033[1;31mType "CLEAN %s" to proceed: \033[0m' "$(hostname)"
  read -r reply
  [[ "$reply" == "CLEAN $(hostname)" ]] || die "Confirmation failed - aborting."
fi

# ---- 1. Stop and remove the receptor service + container -------------------
log "Stopping receptor.service (user scope)"
systemctl --user stop receptor.service 2>/dev/null || true
systemctl --user disable receptor.service 2>/dev/null || true
systemctl --user reset-failed receptor.service 2>/dev/null || true
podman rm -f receptor 2>/dev/null || true

# ---- 2. Remove receptor named volumes -------------------------------------
log "Removing receptor named volumes"
for v in receptor_run receptor_runner receptor_home receptor_data; do
  podman volume rm -f "$v" 2>/dev/null || true
done

# ---- 3. Wipe images/containers from both podman stores --------------------
# Default store holds the receptor image; the custom aap store holds EE images.
if [[ "$REMOVE_IMAGES" == "true" ]]; then
  log "Resetting podman default store"
  podman system reset -f 2>/dev/null || true
  if [[ -f "${AAP_DIR}/containers/storage.conf" ]]; then
    log "Resetting AAP execution-plane store"
    CONTAINERS_STORAGE_CONF="${AAP_DIR}/containers/storage.conf" podman system reset -f 2>/dev/null || true
  fi
fi

# ---- 4. Stop the podman socket + remove its override ----------------------
systemctl --user stop podman.socket 2>/dev/null || true
systemctl --user disable podman.socket 2>/dev/null || true

# ---- 5. Remove systemd units, files and directories -----------------------
log "Removing receptor systemd unit and AAP directories"
rm -f  "$HOME/.config/systemd/user/receptor.service" 2>/dev/null || true
rm -rf "$HOME/.config/systemd/user/podman.service.d" 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user reset-failed 2>/dev/null || true

rm -rf "${AAP_DIR}" 2>/dev/null || true            # tls, receptor/etc, controller/data, containers store
rm -rf "$HOME/.config/containers" 2>/dev/null || true   # containers.conf, certs.d hub trust, auth.json
rm -rf "/run/user/$(id -u)/podman" 2>/dev/null || true

# ---- 6. Host tuning files (sudo) ------------------------------------------
if [[ "$REMOVE_HOST_TUNING" == "true" ]]; then
  log "Removing host-tuning sysctl/limits files"
  sudo rm -f /etc/sysctl.d/99-aap.conf /etc/security/limits.d/99-aap-limits.conf 2>/dev/null || true
  sudo sysctl --system >/dev/null 2>&1 || true
fi

# ---- 7. Close the receptor firewall port (sudo) ---------------------------
if [[ "$CLOSE_FIREWALL" == "true" ]] && command -v firewall-cmd >/dev/null 2>&1; then
  if sudo firewall-cmd --state >/dev/null 2>&1; then
    log "Closing firewalld ${RECEPTOR_PORT}/${RECEPTOR_PROTOCOL} in zone ${RECEPTOR_FIREWALL_ZONE}"
    sudo firewall-cmd --permanent --zone="${RECEPTOR_FIREWALL_ZONE}" --remove-port="${RECEPTOR_PORT}/${RECEPTOR_PROTOCOL}" >/dev/null 2>&1 || true
    sudo firewall-cmd --reload >/dev/null 2>&1 || true
  fi
fi

# ---- 8. Optional: disable linger ------------------------------------------
if [[ "$DISABLE_LINGER" == "true" ]]; then
  log "Disabling systemd linger for $(id -un)"
  sudo loginctl disable-linger "$(id -un)" 2>/dev/null || true
fi

log "Done. Node $(hostname) is ready for a fresh receptor bundle."
echo
echo "Next (from the controller/installer side):"
echo "  ansible-playbook -i inventory generate-exec-node-bundle.yml -e node_hostname=$(hostname)"
echo "  # then copy the tarball to this node and run install-exec-node.yml"
