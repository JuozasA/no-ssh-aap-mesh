#!/usr/bin/env bash
#
# generate-receptor-certs.sh
# ----------------------------------------------------------------------------
# Creates a mesh CA and per-node receptor TLS certificates for AAP 2.7,
# mirroring what the installer generates (roles/receptor/tasks/tls.yml):
#   - CN = node hostname
#   - SAN: DNS:<host> AND otherName:1.3.6.1.4.1.2312.19.1;UTF8:<host>
#     (the receptor node ID - REQUIRED; preflight rejects certs without it)
#   - signed by a local CA (CA:TRUE, keyCertSign) -> use it as custom_ca_cert
#
# Output (./receptor-tls/):
#   ca.key  ca.crt                 <- the mesh CA  (custom_ca_cert)
#   <host>.key  <host>.crt         <- per receptor node (receptor_tls_cert/key)
#
# Re-run safe: regenerates everything. Add hosts by editing NODES below.
# ----------------------------------------------------------------------------
set -euo pipefail

NODES=(
#  ctrl-1.sandbox1920.opentlc.com
#  ctrl-2.sandbox1920.opentlc.com
#  hop-node.srbbx.azure.redhatworkshops.io
  mesh-node.srbbx.azure.redhatworkshops.io
)

OUT="${OUT:-$(dirname "$(realpath "$0")")/receptor-tls}"
KEY_BITS="${KEY_BITS:-4096}"
CA_DAYS="${CA_DAYS:-3650}"      # 10y, matches installer ownca default
NODE_DAYS="${NODE_DAYS:-365}"   # 1y, matches the exec-node bundle default

# DISTINCTIVE subject so a deployed cert is obviously yours, not the installer's
# internal CA (which uses O=Red Hat, OU=Ansible, CN=Ansible Automation Platform).
# On any node: openssl x509 -in ~/aap/receptor/etc/receptor.crt -noout -issuer -subject
# -> issuer CN=${CA_CN} and subject O=${CERT_O} means the custom cert is in use.
CERT_O="${CERT_O:-Custom Mesh}"
CERT_OU="${CERT_OU:-Receptor Mesh}"
CA_CN="${CA_CN:-Custom Receptor Mesh CA}"
SUBJ_BASE="/C=US/ST=North Carolina/L=Raleigh/O=${CERT_O}/OU=${CERT_OU}"

log() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }

command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 1; }
mkdir -p "$OUT"; cd "$OUT"

# ---- 1. Mesh CA ------------------------------------------------------------
if [[ ! -f ca.key || ! -f ca.crt ]]; then
  log "Generating mesh CA (ca.key, ca.crt)"
  openssl genrsa -out ca.key "$KEY_BITS" 2>/dev/null
  chmod 0400 ca.key
  openssl req -x509 -new -nodes -key ca.key -sha256 -days "$CA_DAYS" -out ca.crt \
    -subj "${SUBJ_BASE}/CN=${CA_CN}" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign"
else
  log "Reusing existing CA (ca.key, ca.crt)"
fi

# ---- 2. Per-node receptor certificates -------------------------------------
for host in "${NODES[@]}"; do
  log "Generating receptor certificate for ${host}"
  cnf="$(mktemp)"
  cat > "$cnf" <<EOF
[req]
distinguished_name = dn
req_extensions     = v3_req
prompt             = no

[dn]
C  = US
ST = North Carolina
L  = Raleigh
O  = ${CERT_O}
OU = ${CERT_OU}
CN = ${host}

[v3_req]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName   = @alt_names

[alt_names]
DNS.1       = ${host}
otherName.1 = 1.3.6.1.4.1.2312.19.1;UTF8:${host}
EOF

  openssl genrsa -out "${host}.key" "$KEY_BITS" 2>/dev/null
  chmod 0400 "${host}.key"
  openssl req -new -key "${host}.key" -out "${host}.csr" -config "$cnf"
  openssl x509 -req -in "${host}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out "${host}.crt" -days "$NODE_DAYS" -sha256 \
    -extfile "$cnf" -extensions v3_req 2>/dev/null
  rm -f "${host}.csr" "$cnf"
done

# ---- 3. Verify the node-ID SAN is present ----------------------------------
echo
log "Verifying receptor node-ID SAN (OID 1.3.6.1.4.1.2312.19.1) on each cert"
ok=1
for host in "${NODES[@]}"; do
  if openssl x509 -in "${host}.crt" -noout -text | grep -q "1.3.6.1.4.1.2312.19.1"; then
    printf '    \033[1;32mOK\033[0m   %s\n' "$host"
  else
    printf '    \033[1;31mMISSING\033[0m %s\n' "$host"; ok=0
  fi
done
[[ $ok -eq 1 ]] || { echo "One or more certs lack the receptor OID SAN" >&2; exit 1; }

echo
log "Distinctive DN (this is how you confirm the custom cert is in use):"
openssl x509 -in ca.crt -noout -issuer | sed 's/^/    CA  /'
for host in "${NODES[@]}"; do
  openssl x509 -in "${host}.crt" -noout -subject | sed "s/^/    crt /"
done

cat <<SUMMARY

Files in ${OUT}:
  ca.crt / ca.key                 -> mesh CA   (set custom_ca_cert=$(realpath ca.crt))
  <host>.crt / <host>.key         -> per node  (receptor_tls_cert / receptor_tls_key)

Inventory wiring:
  custom_ca_cert=$(realpath ca.crt)
  # controllers (main installer):
  ctrl-1.sandbox1920.opentlc.com receptor_tls_cert=$(realpath ctrl-1.sandbox1920.opentlc.com.crt) receptor_tls_key=$(realpath ctrl-1.sandbox1920.opentlc.com.key)
  ctrl-2.sandbox1920.opentlc.com receptor_tls_cert=$(realpath ctrl-2.sandbox1920.opentlc.com.crt) receptor_tls_key=$(realpath ctrl-2.sandbox1920.opentlc.com.key)
  # hop node (out-of-band bundle): set the same two vars on its inventory line;
  # generate-exec-node-bundle.yml imports them and folds ca.crt into mesh-CA.crt.
SUMMARY
