# Kubernetes Multi-Master Cluster Bootstrap Script

This Bash script automates the setup of a Kubernetes multi-master cluster with worker nodes on Ubuntu hosts. It installs prerequisites, Docker, and Kubernetes components, configures system settings, initializes the first control plane node, joins additional masters, and adds worker nodes. Calico is applied as the default CNI (network plugin).

---

## Features

* Prepares Ubuntu nodes with necessary packages and kernel modules.
* Installs Docker and Kubernetes components (`kubeadm`, `kubelet`, `kubectl`) and locks versions.
* Disables swap for Kubernetes compatibility.
* Configures sysctl for networking (required for pods).
* Initializes a HA-enabled Kubernetes control plane with multiple masters.
* Automatically joins worker nodes to the cluster.
* Applies Calico networking.

---

## Prerequisites

1. **SSH Access**
   Passwordless SSH (via key) from the host running this script to all nodes.
   Default user: `ubuntu` (customizable via `SSH_USER`).
   Default key: `~/.ssh/id_rsa` (customizable via `SSH_KEY`).

2. **Ubuntu Nodes**
   Tested on Ubuntu 20.04/22.04.

3. **Network Requirements**
   * Control plane endpoint IP (HAProxy or load balancer) must be reachable.
   * Nodes must be able to reach each other over the pod network (default `192.168.0.0/16`).

---

## Configuration

Modify the following variables at the top of the script:

```bash
SSH_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_rsa"
CONTROL_PLANE_ENDPOINT="192.168.1.106:6443" # HA Proxy Load Balancer IP
KUBE_MASTER="192.168.1.100" # Master 1 IP
MASTER2="192.168.1.101"     # Master 2 IP
WORKERS=(192.168.1.102 192.168.1.103 192.168.1.104 192.168.1.105)
```

Optional: SSH password support via `PASSWORD` environment variable.

---

## Usage

```bash
chmod +x bootstrap_k8s.sh
./bootstrap_k8s.sh
```

The script will:

1. Check SSH connectivity to all hosts.
2. Install Docker, Kubernetes components, and dependencies.
3. Disable swap and configure networking sysctl.
4. Initialize the first Kubernetes master node.
5. Join additional masters using certificate key for HA.
6. Join all worker nodes.
7. Apply Calico CNI.

---

## Verification

After completion, verify the cluster:

```bash
kubectl --kubeconfig /home/ubuntu/.kube/config get nodes
kubectl --kubeconfig /home/ubuntu/.kube/config get pods -A
```

---

## Notes

* The script uses `kubeadm init` with `--control-plane-endpoint` for HA.
* Calico is applied as the default networking plugin. Modify the manifest URL if a different CNI is preferred.
* Docker and Kubernetes versions are held (`apt-mark hold`) to prevent unintended upgrades.
* Swap must remain off for Kubernetes to function properly.

---

## Troubleshooting

* **SSH Failures**: Ensure `SSH_USER`, `SSH_KEY`, and network access are correct.
* **Swap Issues**: Check `/etc/fstab` for commented swap entries.
* **Pod Network Issues**: Ensure `192.168.0.0/16` pod network does not overlap with existing network.

---
