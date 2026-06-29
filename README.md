# AAP 2.7 Containerized — Remote Automation Mesh Deployment

Not the official Red Hat documentation. For the Support Exception for this Deployment type, reach out to your Red Hat Account Team.

## Overview

| Aspect | This deployment |
|--------|-----------------|
| Database | **External AWS RDS PostgreSQL** (admin-credentials mode — the installer creates the component DBs/roles using the RDS master account) |
| Control plane | `automationcontroller` (×2), `automationgateway`, `automationhub`, `automationmetrics`, `redis` — reachable over SSH from the installer host |
| Execution mesh | Hop / execution nodes installed **out-of-band** via a self-contained bundle (no SSH from the installer) |
| Receptor TLS | Custom per-node certificates signed by a custom mesh CA (`custom_ca_cert`) |

Two facts drive most of the procedures below:

1. **The external DB is RDS** 
2. **The mesh nodes are out-of-band** — they are not reachable by the installer.
---

## Architecture, components & sizing

### Components

AAP 2.7 is fronted by the **Platform Gateway**, which is the single entry point (UI/API) and reverse-proxies to the backend services. Each service runs as rootless podman containers managed by user-level systemd.

| Component | Role | Notes |
|-----------|------|-------|
| **Platform Gateway** | Front door — auth, routing, UI/API aggregation | User-facing on 80/443 (Envoy). Uses Redis. |
| **Automation Controller** | Job execution, inventories, projects, RBAC | Dispatches work across the receptor mesh. |
| **Automation Hub** | Private content (collections, EEs) | Storage-heavy; backend can be `file`/S3/Azure. |
| **Automation EDA** | Event-Driven Ansible | Optional. |
| **Automation Metrics** | Metrics/analytics service | Reads the controller DB via a read-only user. |
| **Redis** | Shared cache / message backend | Standalone or cluster (see below). |
| **Receptor mesh** | Control ↔ execution/hop node transport | mTLS on 27199. |
| **PostgreSQL** | Backing database | **External AWS RDS** in this deployment. |

### Reference topologies

Red Hat documents two reference topologies for containerized AAP 2.7 (see the [install guide PDF](https://docs.redhat.com/en/documentation/red_hat_ansible_automation_platform/2.7/pdfs/aap-install-2-7-pdf.pdf)). Both use the **same traffic flows** (80/443 ingress, 5432 DB, 6379 Redis, 27199 receptor); they differ in redundancy.

| | **AIO Growth** (all-in-one) | **Enterprise** (multi-node) |
|---|-----------|----------------|
| Inventory file | `inventory-growth` (`ansible_connection=local`) | `inventory` (the default) |
| Component instances | one of each, colocated on a single host | redundant (e.g. 2× gateway / controller / hub / EDA / metrics) |
| Database | containerized `[database]` host **or** external | **external** (e.g. AWS RDS) |
| Redis | **standalone** | **cluster** (≥ 6 instances, one per control-plane VM) |
| Front end | direct to the gateway | **HA load balancer / proxy** in front of the gateways (443) |
| Execution mesh | optional | hop node(s) + execution node(s) over receptor |
| Use | dev / test / small production | large-scale production / HA |

**This deployment follows the Enterprise topology:** external AWS RDS, redundant automation controllers, Redis across the control plane, and an out-of-band execution mesh (hop + execution nodes). If you run more than one gateway, put a load balancer in front of them on 443 (the diagram's "HA proxy / load balancer").


### Ports & firewall rules

The installer opens these via `firewalld` (zone `public` by default) **only when firewalld is enabled**. Backend app ports (uwsgi/daphne/gunicorn/api: 8050/8051/8052, 8000/8001, 24816/24817) bind to localhost and are **not** firewalled.

**Required flows:**

| Flow | Port(s) | Proto | Purpose |
|------|---------|-------|---------|
| Clients → Gateway | **443** (and 80) | tcp | Platform UI/API (Envoy front door) |
| Admin/installer → all control-plane nodes | **22** | tcp | SSH (passwordless + sudo) |
| Gateway → backend services *(distributed only)* | 8443 (controller), 8444 (hub), 8445 (eda), 8450 (metrics), 8446 (gateway nginx) | tcp | Reverse-proxy to each service's nginx |
| Control plane ↔ Redis | **6379** (+ **16379** cluster bus) | tcp | Cache / message backend |
| Controller/Gateway/Hub/EDA/Metrics → **RDS** | **5432** | tcp | PostgreSQL (RDS security group, not firewalld) |
| Controller ↔ execution/hop nodes | **27199** | tcp | Receptor mesh (mTLS) |
| (optional) monitoring → control plane | 44321 / 44322 | tcp | Performance Co-Pilot (`setup_monitoring=true`) |

Per-service ports the installer opens (http / https): controller 8080/8443 · hub 8081/8444 · eda 8082/8445 · gateway 8083/8446 (+ Envoy 80/443) · metrics 8087/8450. On a single colocated node these are loopback; on a distributed control plane they must be reachable between nodes.

> RDS note: the `:5432` rule is an **AWS security group** ingress from the control-plane subnet — there is no firewalld rule because the DB isn't an AAP-managed host.

### Sizing per VM

The install guide specifies the **same minimum for every VM** (the installer enforces only the RAM check, `ansible_memtotal_mb >= 15000`; **hop nodes are exempt**):

| Resource | Minimum |
|----------|---------|
| RAM | **16 GB** — *32 GB* for a Growth bundled install with `hub_seed_collections=true` |
| CPU | **4 vCPU** |
| Local disk | **60 GB total** |
| Disk IOPS | **3000** |

Disk breakdown within that 60 GB:

| Path | Minimum |
|------|---------|
| Installation directory (if on its own partition) | 15 GB |
| `/tmp` (offline / bundled install) | 10 GB |
| `/var/tmp` (bundled / offline; 1 GB online) | 3 GB |
| `/var/lib/containers` (image storage) | 10 GB |

Role-specific notes:
- **Hub** content (collections, EEs) grows well beyond the minimum — size its disk for what you sync.
- **Metrics service** can run smaller (2 vCPU / 4 GB) and needs ~20–40 GB for the `metrics_service` database (on the RDS side here).
- **Where storage goes (rootless):** images/containers live under the install user's **home** (`~/.local/share/containers` + `~/aap/containers/storage` for EE images) and runtime data under `~/aap` — put the bulk of the disk on the home filesystem. **Podman does not support image storage on NFS.**

### Redis: standalone vs cluster

`redis_mode` defaults to **`cluster`**. TLS is on by default (`redis_disable_tls=false`).

| Mode | Set | Nodes | HA | When |
|------|-----|-------|----|----|
| **Cluster** (default) | `redis_mode=cluster` | **≥ 6 Redis instances** (3 primary + 3 replica; `redis_cluster_replicas=1`) across the `[redis]` group | Yes | Production / HA control plane |
| **Standalone** | `redis_mode=standalone` | 1 instance | No | Small / non-HA footprints, or fewer than 6 nodes |

Notes:
- In cluster mode the `[redis]` inventory group must contain at least 6 hosts; the cluster uses the **bus port 16379** in addition to 6379.
- The Gateway connects to Redis on **6379**; Controller and Hub also use a local Redis over a **unix socket** (no extra port).
- Choosing standalone removes Redis as an HA dependency but makes it a single point of failure — fine for labs/PoCs, not recommended for production.

---

## Prerequisites

- **RHEL 9.2 or later** on every node (RHEL 8 is **not** supported; RHEL 10 is also supported). Each host needs an **FQDN** hostname (`hostname -f`).
- A **dedicated non-root user** with `sudo` on each node — this user both runs the install and is the service account for the containers.
- Each VM meets the [sizing minimums](#sizing-per-vm): 16 GB RAM, 4 vCPU, 60 GB disk, 3000 IOPS.
- `ansible-core`, `podman`, and `psql` on the installer host (`sudo dnf install -y ansible-core postgresql`).
- Passwordless SSH (public-key) from the installer host to every **control-plane** node, with passwordless `sudo`.
- An **external PostgreSQL** instance (AWS RDS here): **PostgreSQL 15, 16, or 17**, with **ICU support** (a hard requirement for external DBs), reachable on `:5432` from the control-plane subnet. Note: external PG 16/17 rely on external backup/restore (the built-in backup uses PG15 utilities).

### About `custom_ca_cert`

`custom_ca_cert` is a **single** file that the installer uses for **two** things at once:

- it is added to the in-container system trust (`/etc/pki/tls/certs/ca-bundle.crt`), which every component uses as `sslrootcert` for Postgres `verify-full`; **and**
- it is concatenated into receptor's `mesh-CA.crt`.

So when you use both custom receptor certs **and** RDS `verify-full`, `custom_ca_cert` must contain **both** the receptor mesh CA and the RDS CA. Because it lands in `mesh-CA.crt`, it is bound by receptor's ~16 KB QUIC limit — **use the regional RDS bundle (~4–5 KB), never the global one (~165 KB)**, which would break the mesh with `CRYPTO_BUFFER_EXCEEDED`. The merged file is `receptor-tls/custom-ca-bundle.pem`.

---

## Installation

### 1. Inventory

Set the RDS connection and admin credentials, the component DB names/users, the receptor TLS vars, and `custom_ca_cert`. Example (abbreviated):

```ini
[all:vars]
postgresql_admin_username=<rds-master-user>
postgresql_admin_password=<rds-master-password>
custom_ca_cert=/abs/path/receptor-tls/custom-ca-bundle.pem

controller_pg_host=<rds-endpoint>
controller_pg_database=ctrl-db
controller_pg_username=postgres-ctrl
controller_pg_password=...
controller_pg_sslmode=verify-full
# ... gateway_/hub_/eda_/automationmetrics_ equivalents, each *_pg_sslmode=verify-full
```

### 2. Exclude the out-of-band mesh nodes from the installer run

The hop/execution nodes are not reachable by the installer, so they are excluded from the `install` run with **`--limit '!execution_nodes'`** (applied in the next step). **Keep them in the inventory — do not comment them out.**

> ⚠️ Commenting the nodes out removes them from the inventory, which makes the controller's `init.yml` *"Deprovision Instances not listed in the inventory"* task (`awx-manage deprovision_instance`) drop them from the mesh database. `--limit` keeps them in `groups['execution_nodes']` (so the controller registers them in the DB) while preventing Ansible from connecting to the unreachable hosts.

### 3. Run the installer (control plane)

```bash
ansible-playbook -i inventory ansible.containerized_installer.install --limit '!execution_nodes'
```

This installs the control plane and the controllers' own receptor instances, creates the remaining component databases on RDS, and registers the (still-excluded) mesh nodes in the controller database so they're ready for their bundles.

### 4. Build and deploy the mesh-node bundles

The mesh nodes stay in the inventory throughout. For each hop/execution node, build its bundle on the controller (the generator reads the node's vars from the inventory and connects only to the controller):

```bash
ansible-playbook -i inventory generate-exec-node-bundle.yml -e node_hostname=hop-node.srbbx.azure.redhatworkshops.io
```

The tarball is fetched back to `~/receptor-bundle-<node>.tar.gz`. Copy it to the node and install:

```bash
tar -xzf receptor-bundle-<node>.tar.gz && cd receptor-bundle-<node>/
ansible-playbook install-exec-node.yml -i inventory.yml
```

If you use custom receptor certs, set `receptor_tls_cert`/`receptor_tls_key` on the node's inventory line first — the bundle generator imports them and folds `custom_ca_cert` into the node's `mesh-CA.crt`. (This requires the controllers to have been installed **with** `custom_ca_cert` set, so `~/aap/tls/custom.cert` exists on them.)

### 5. Verify

- Control plane: `podman ps` on each host; log in to the platform UI.
- Mesh: on each node `systemctl --user status receptor.service`, then in the UI **Administration → Topology View** / **Instances** should show the hop/execution nodes healthy.
- Custom certs in use (on a node): `openssl x509 -in ~/aap/receptor/etc/receptor.crt -noout -issuer` should show your custom CA, not `CN=Ansible Automation Platform`.

---

## Uninstallation

> **Order matters.** The host cleanup regenerates secrets and the RDS wipe clears encrypted data — they are a matched pair. Doing one without the other leaves a half-state.

### 1. Exclude the out-of-band mesh nodes

The uninstall playbook would try to reach them and fail (`any_errors_fatal`), so exclude them with **`--limit '!execution_nodes'`** (applied in the next step). Commenting them out also works here — `uninstall.yml` doesn't run the deprovision task and the RDS database is wiped anyway — but `--limit` keeps it consistent with install/upgrade.

### 2. Run the uninstall playbook (control plane)

```bash
ansible-playbook -i inventory ansible.containerized_installer.uninstall --limit '!execution_nodes'
```

### 3. Wipe the RDS databases and roles

The uninstall does **not** touch RDS. Drop the AAP databases/roles so a fresh install doesn't collide.

### 4. Clean the control-plane hosts

Removes the `~/aap` dir, podman volumes/secrets/images, systemd units, `~/.config/containers` left behind by the playbook.

### 5. Clean the hop/execution nodes manually

The playbook can't reach them — clean each one on the node itself.

---

## Upgrades

An upgrade is an **in-place re-run of the installer from a newer bundle against the existing databases** — you do **not** wipe RDS, and you do **not** clean the hosts (that would destroy the secret keys needed to decrypt existing DB data).

### 1. Stage the new bundle

1. Download and extract the new AAP 2.7 bundle into a new directory.
2. Copy your deployment files into it:
   - `inventory`
   - `generate-exec-node-bundle.yml` and `install-exec-node.yml`
   - the custom certificates (including `custom-ca-bundle.pem`)
3. Update absolute paths in the inventory if the new directory path differs.

### 2. Exclude the out-of-band mesh nodes with `--limit` — **do not comment them out**

The hop/execution nodes are not reachable by the installer, so they must be excluded from the upgrade run. **Use `--limit '!execution_nodes'`, not commenting** (the install command in the next step applies it).

> ⚠️ **Never comment out the mesh nodes for an upgrade.** The controller's `init.yml` has a *"Deprovision Instances not listed in the inventory"* task (`awx-manage deprovision_instance`). A node absent from the inventory is **removed from the mesh database**. `--limit` keeps the nodes in `groups['execution_nodes']` so they stay registered — registration runs as `awx-manage` on the controller and never needs to reach them — while keeping Ansible from connecting to the unreachable hosts.

### 3. Upgrade the control plane

From the new bundle directory:

```bash
ansible-playbook -i inventory ansible.containerized_installer.install --limit '!execution_nodes'
```

The installer pulls the new images, runs DB migrations against the existing RDS databases, and recreates the services. (Because the hosts are untouched, the existing secret keys still decrypt the existing DB data.) The `--limit` keeps the mesh nodes registered (see step 2).

### 4. Upgrade the mesh

Regenerate each node's bundle from the new version and redeploy:

```bash
# on the controller (mesh nodes remain in the inventory):
ansible-playbook -i inventory generate-exec-node-bundle.yml -e node_hostname=<node>
# copy the tarball to the node, then on the node:
tar -xzf receptor-bundle-<node>.tar.gz && cd receptor-bundle-<node>/
ansible-playbook install-exec-node.yml -i inventory.yml
```

`install-exec-node.yml` recreates the receptor container from the new image (`recreate: true`), so the same command upgrades the node in place.

### 5. Verify

Same checks as install step 5: control-plane containers, mesh Topology View, and that all nodes report the new version.
