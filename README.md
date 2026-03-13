# AAP Containerized - Non-SSH Execution/Hop Node Setup Guide

# **Overview**

This guide explains how to install AAP containerized with a mixed execution node topology:

-   AAP control plane (Gateway, Controller, Hub, EDA) - SSH accessible, installed by the main AAP installer.

-   Execution/Hop nodes SSH accessible, installed automatically by the main AAP installer alongside the control plane.

-   Execution/Hop nodes no SSH from the installer machine. Installed via the bundle approach described in this guide.

Key concept --- receptor topology direction:

-   Hop nodes dial OUTBOUND to the AAP Controllers (hop → controllers).

-   Controllers do NOT dial to Hop nodes.

-   This means Hop nodes only need outbound access to Controller port 27199. They do NOT need inbound port 27199 from the Controllers.

-   Execution nodes dial outbound to their Hop node (execution → hop).

-   Hop nodes DO need inbound port 27199 open from the Execution node's network.

# **Prerequisites**

## **Node requirements:**

-   RHEL 9.2+

-   ansible-core installed: dnf install ansible-core

-   sudo / become access for the service user

-   Outbound TCP 27199 to peer nodes (hop → controllers, exec → hop)

-   Inbound TCP 27199 from child nodes (hop node needs inbound from exec node network)

-   No inbound port 27199 needed from controllers (hop dials out, not controllers)

## **Installer machine requirements:**

-   AAP bundle downloaded and extracted (e.g. ansible-automation-platform-containerized-setup-bundle-2.6-5-x86_64/)

-   Main installer has completed successfully against the control plane

-   community.crypto collection available (ships with the AAP bundle)

# **Files You Need to Create or Modify**

Three files are involved:

-   inventory - modified to add the child-group structure for execution nodes

-   generate-exec-node-bundle.yml - new playbook, placed in the installer root directory

-   install-exec-node.yml - new playbook, placed in the installer root directory

# **Step 1 - Update the Inventory**

## **1a. Controller section --- prevent auto-assignment**

Add these group vars to [automationcontroller]. They prevent the installer from auto-assigning execution nodes directly to controllers (which would break topology when those exec nodes are excluded from the **--limit**):
```
[automationcontroller]
automationcontroller-1.example.com
automationcontroller-2.example.com

**[automationcontroller:vars]**
# receptor_peers (no underscore) --- prevents installer auto-assigning exec node directly to controllers
**receptor_peers=[]**
# _receptor_peers (with underscore) --- init.yml Jinja2 guard for excluded node processing
**_receptor_peers=[]**
```
Why both? The installer's init.yml reads **_receptor_peers** (underscore) from hostvars for ALL execution nodes to build receptor topology. For excluded (non-SSH) nodes, facts.yml never runs so **_receptor_peers** would be undefined causing template generation to crash. Setting **_receptor_peers=[]** everywhere prevents this.
**receptor_peers** (no underscore) is the input variable that controls topology assignment.

## **1b. Execution nodes --- child group structure**

Replace any existing [execution_nodes] section with this child-group pattern:
```
**[execution_nodes:children]
ssh_execution_nodes
nossh_execution_nodes**

**[execution_nodes:vars]
_receptor_peers=[]
_receptor_protocol=tcp
_receptor_port=27199**

[ssh_execution_nodes]
ssh-hop-1.example.com **receptor_peers=["automationcontroller-1.example.com","automationcontroller-2.example.com"] receptor_type=hop**
ssh-exec-1.example.com **receptor_peers=["aws-hop-1.example.com"] receptor_type=execution**

[nossh_execution_nodes]
no-ssh-hop.example.com **receptor_peers=["automationcontroller-1.example.com","automationcontroller-2.example.com"] _receptor_hostname=no-ssh-hop.example.com _receptor_type=hop _system_uuid=ec2a2b88-a646-74b8-3053-e2beec**
no-ssh-exec.example.com **receptor_peers=["no-ssh-hop.example.com"] _receptor_hostname=on-prem-exec.example.com _receptor_type=execution _system_uuid=ec2824db-c7ab-bcde-b3a1-c7eee**
```
## **1c. Variable naming rules**

For SSH-accessible nodes (e.g. [ssh_execution_nodes]):

-   Use receptor_type=hop (NO underscore) for hop nodes. Omit entirely for execution nodes (role default is 'execution').

-   Do NOT set _system_uuid - it is auto-discovered from ansible_product_uuid / ansible_machine_id by facts.yml.

-   Do NOT set _receptor_type (UNDERSCORE) directly - facts.yml reads receptor_type and converts it to _receptor_type via set_fact. If you set _receptor_type in inventory, facts.yml will overwrite it with the role default ('execution').

For non-SSH nodes (e.g. [nossh_execution_nodes]):

-   Use _receptor_type=hop (WITH underscore) - facts.yml never runs so you must provide the underscore form directly.

-   _system_uuid MUST be set - it cannot be auto-discovered. Obtain it from the node:

    -   `cat /sys/class/dmi/id/product_uuid` or `cat /etc/machine-id`

-   _receptor_hostname MUST be set - the FQDN/hostname receptor advertises to the mesh.

-   receptor_peers MUST be set - the list of peers this node dials out to (JSON array format).

Example Inventory file:
[[https://github.com/JuozasA/no-ssh-aap-mesh/blob/main/inventory]{.underline}](https://github.com/JuozasA/no-ssh-aap-mesh/blob/main/inventory)

# **Step 2 - generate-exec-node-bundle.yml**

## **What this playbook does**

generate-exec-node-bundle.yml runs ON the first AAP controller node (not on the target exec/hop node). It:

1.  Reads TLS certificates and the CA key from the controller's `~/aap/tls/` directory (created by the main installer).

2.  Generates a new TLS certificate for the target node, signed by the mesh CA.

3.  Reads node properties (_receptor_type, receptor_peers, etc.) from the inventory hostvars.

4.  Renders a receptor.conf using the same template as the installer.

5.  Registers the node's peer links in the database (awx-manage register_peers) - this is what makes the node appear in AAP's Topology View.

6.  Copies the receptor container image (and EE images for execution nodes) from the installer bundle.

7.  Bundles the Ansible collections (containers.podman, ansible.posix) needed to run install-exec-node.yml offline.

8.  Packages everything into a self-contained tarball: `~/receptor-bundle-<hostname>.tar.gz`.

9.  Fetches the tarball back to the installer machine.

Two modes:

-   Mode A (default, installer_on_controller=false): Installer is on a separate machine. Images are pushed from the installer to the controller during staging.

-   Mode B (installer_on_controller=true): Installer runs on the same machine as the controller. Images are read locally.

Place this file in the installer root directory:

generate-exec-node-bundle.yml -
[[https://github.com/JuozasA/no-ssh-aap-mesh/blob/main/generate-exec-node-bundle.yml]{.underline}](https://github.com/JuozasA/no-ssh-aap-mesh/blob/main/generate-exec-node-bundle.yml)

# **Step 3 - install-exec-node.yml**

## **What this playbook does**

install-exec-node.yml is packaged inside the bundle tarball and runs ON the hop/execution node itself (not on the installer machine or controller). It:

1. Installs prerequisites: podman, crun, podman-remote, slirp4netns, fuse-overlayfs, polkit.

2. Creates the AAP directory structure under `~/aap/` (mirroring the installer's roles/common layout).

3. Sets the SELinux context data_home_t on `~/aap/containers/storage` --- this is critical: it triggers a SELinux type transition so the podman daemon labels image layer files as `container_file_t` (which EE container processes can read).

4. Configures podman: containers.conf (crun runtime), storage.conf (custom storage path), podman.service.d/override.conf (daemon storage config), podman wrapper script.

5. Extracts the CA trust bundle into `~/aap/tls/extracted/` (bind-mounted into the receptor container).

6. Deploys receptor.conf and TLS certificates into `~/aap/receptor/etc/`.

7. Creates named podman volumes: receptor_run, receptor_runner, receptor_home, receptor_data.

8. Loads container images from the bundle (receptor + EE images for execution nodes).

9. Creates the receptor container with all required volume mounts and generates a systemd unit file.

10. Enables and starts receptor.service (user scope).

11. Opens port `27199/tcp` in firewalld if running.

12. Verifies the receptor service is active.

Place this file in the installer root directory:

install-exec-node.yml -
[[https://github.com/JuozasA/no-ssh-aap-mesh/blob/main/install-exec-node.yml]{.underline}](https://github.com/JuozasA/no-ssh-aap-mesh/blob/main/install-exec-node.yml)

# **Step 4 - Run the Main AAP Installer**

Run the installer, excluding non-SSH node groups:
```
cd /home/ec2-user/ansible-automation-platform-containerized-setup-bundle-2.6-5-x86_64/

ansible-playbook -i inventory ansible.containerized_installer.install **--limit 'all:!nossh_execution_nodes'**
```
This installs the control plane (Gateway, Controller, Hub, EDA) and any SSH-accessible execution nodes, but skips no-ssh nodes.

Wait for the installer to complete successfully before proceeding. Verify in the AAP UI:

-   Administration → Instances --- all control plane nodes show as Running

-   The installer creates the mesh CA, receptor certificates, and the signing key on the controller - these are required by generate-exec-node-bundle.yml

# **Step 5 - Generate Bundle for Each Non-SSH Node**

Run once per node, always starting with the hop node (execution nodes peer to the hop, so the hop must be registered first).

## **5a. Hop node**
```
ansible-playbook -i inventory generate-exec-node-bundle.yml -e node_hostname=no-ssh-hop.example.com

Output: ~/receptor-bundle-no-ssh-hop.example.com.tar.gz
```
## **5b. Execution node**
```
ansible-playbook -i inventory generate-exec-node-bundle.yml -e node_hostname=no-ssh-exec.example.com

Output: ~/receptor-bundle-no-ssh-exec.example.com.tar.gz
```
## **5c. If installer runs on the controller (Mode B)**
```
ansible-playbook -i inventory generate-exec-node-bundle.yml -e node_hostname=<hostname> **-e installer_on_controller=true**
```

# **Step 6 - Transfer Bundle to the Node**

# **Step 7 - Install on the Node**

SSH onto the node (or use whatever access method is available - console, serial, jump host)

Install ansible-core if not already present:

`sudo dnf install -y ansible-core`

Extract the bundle and run the playbook:
```
tar -xzf receptor-bundle-<hostname>.tar.gz
cd receptor-bundle-<hostname>/
ansible-playbook install-exec-node.yml -i inventory.yml
```
Repeat Steps 5--7 for each non-SSH node. Always install the hop node before the execution node.

# **Step 8 - Verify in AAP**

1. Log into the AAP UI.

2. Go to Instances.

3. Confirm both the hop and execution nodes show status: Ready.

4. Go to Topology View to confirm the mesh topology is correct.
