#!/usr/bin/env bash
set -euo pipefail

SSH_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_rsa"
CONTROL_PLANE_ENDPOINT="192.168.1.106:6443" # HA Proxy Load Balancer IP
KUBE_MASTER="192.168.1.100" # Master 1 IP
MASTER2="192.168.1.101" # Master 2 IP

WORKERS=(192.168.1.102 192.168.1.103 192.168.1.104 192.168.1.105)
ALL_HOSTS=("$KUBE_MASTER" "$MASTER2" "${WORKERS[@]}")
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

run_remote() {
    local host="$1"
    ssh -i "$SSH_KEY" $SSH_OPTS "$SSH_USER@$host" "$@"
}

copy_remote() {
    local src="$1"
    local host="$2"
    local dst="$3"
    if [[ -n "$PASSWORD" ]]; then
        sshpass -p "$PASSWORD" scp $SSH_OPTS "$src" "$SSH_USER@$host:$dst"
    else
        scp -i "$SSH_KEY" $SSH_OPTS "$src" "$SSH_USER@$host:$dst"
    fi
}

echo "Checking SSH connectivity..."
for h in "${ALL_HOSTS[@]}"; do
    if ! run_remote "$h" echo ok >/dev/null 2>&1; then
        echo "ERROR: Cannot SSH to $h. Exiting."
        exit 1
    else
        echo "OK: $h"
    fi
done

NODE_PREP_SCRIPT=$(cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { echo "[PREP] $*"; }

log "Updating apt and installing prerequisites..."
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

log "Installing Docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --batch --yes --trust-model always -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo apt-mark hold docker-ce docker-ce-cli containerd.io

log "Disabling swap..."
sudo swapoff -a || true
sudo sed -i '/ swap / s/^/#/' /etc/fstab || true

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet && sudo systemctl start kubelet

log "Configuring sysctl..."
sudo modprobe br_netfilter || true
sudo tee /etc/sysctl.d/k8s.conf >/dev/null <<SYSCTL
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
SYSCTL
sudo sysctl --system || true
log "PREP DONE"
EOF
)

echo "==> Running package + kube pre requisites on all hosts..."
for h in "${ALL_HOSTS[@]}"; do
    echo "--> prepping ${h}"
    TMP_SCRIPT="/tmp/node_prep.sh"
    echo "$NODE_PREP_SCRIPT" > /tmp/node_prep.sh
    copy_remote /tmp/node_prep.sh "$h" "$TMP_SCRIPT"
    run_remote "$h" "bash $TMP_SCRIPT"
done

echo "==> Initializing first master ${KUBE_MASTER} ..."
INIT_CMD="sudo kubeadm init --control-plane-endpoint ${CONTROL_PLANE_ENDPOINT} --upload-certs --pod-network-cidr=192.168.0.0/16"
run_remote "$KUBE_MASTER" "$INIT_CMD | tee /tmp/kubeadm_init_output.txt && mkdir -p /home/${SSH_USER}/.kube && sudo cp /etc/kubernetes/admin.conf /home/${SSH_USER}/.kube/config && sudo chown ${SSH_USER}:${SSH_USER} /home/${SSH_USER}/.kube/config && kubeadm token create --print-join-command > /tmp/kubeadm_join_cmd.sh && sudo kubeadm init phase upload-certs --upload-certs > /tmp/kubeadm_cert_key.txt || true"

run_remote "$KUBE_MASTER" "kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml || true"

JOIN_CMD_RAW=$(run_remote "$KUBE_MASTER" "cat /tmp/kubeadm_join_cmd.sh")
CERT_KEY_LINE=$(run_remote "$KUBE_MASTER" "sudo grep -oP '(?<=--certificate-key )\S+' /tmp/kubeadm_cert_key.txt || true")
JOIN_MASTER_CMD="${JOIN_CMD_RAW} --control-plane"

if [[ -n "$CERT_KEY_LINE" ]]; then
  JOIN_MASTER_CMD="${JOIN_MASTER_CMD} --certificate-key ${CERT_KEY_LINE}"
fi
run_remote "$MASTER2" "$JOIN_MASTER_CMD | tee /tmp/kubeadm_join_master.log"

for w in "${WORKERS[@]}"; do
    echo "--> joining worker ${w}"
    run_remote "$w" "$JOIN_CMD_RAW | tee /tmp/kubeadm_join_worker.log"
done

echo "==> Bootstrap completed."
echo "Use kubectl on ${KUBE_MASTER}: kubectl --kubeconfig /home/${SSH_USER}/.kube/config get nodes"