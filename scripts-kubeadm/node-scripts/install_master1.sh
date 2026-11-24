#!/usr/bin/env bash
# install_master1.sh - Run ONLY on the FIRST control plane node

set -euo pipefail

echo "⏳ Waiting for cloud-init to finish..."
cloud-init status --wait

echo "⚙️ Bootstrapping FIRST Kubeadm Control Plane..."

source /etc/environment
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/16"
LB_IP="192.168.56.30"

# 1. Initialize control plane with HA endpoint
sudo kubeadm init \
    --control-plane-endpoint "${LB_IP}:6443" \
    --upload-certs \
    --pod-network-cidr "${POD_CIDR}" \
    --service-cidr "${SERVICE_CIDR}" \
    --apiserver-advertise-address "${PRIMARY_IP}"

# 2. Configure kubeconfig for the current user and root
setup_kubeconfig() {
    local target_user=$1
    local target_home=$2
    
    echo "🔑 Configuring kubeconfig for user: $target_user"
    mkdir -p "$target_home/.kube"
    sudo cp -f /etc/kubernetes/admin.conf "$target_home/.kube/config"
    sudo chown "$target_user":"$target_user" "$target_home/.kube/config"
    chmod 600 "$target_home/.kube/config"
}

# Always setup for root
setup_kubeconfig "root" "/root"

# If run via sudo, setup for the original user too
if [ -n "${SUDO_USER:-}" ]; then
    SUDO_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    setup_kubeconfig "$SUDO_USER" "$SUDO_HOME"
fi

# 3. Install Calico CNI
echo "🌐 Installing Calico CNI..."
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.1/manifests/tigera-operator.yaml

echo "⏳ Waiting for Calico CRDs to appear..."
until kubectl get crd installations.operator.tigera.io &>/dev/null; do
  echo -n "."
  sleep 2
done
echo " established!"

# Now wait for it to be fully ready
kubectl wait --for=condition=established --timeout=60s crd/installations.operator.tigera.io

curl -LO https://raw.githubusercontent.com/projectcalico/calico/v3.30.1/manifests/custom-resources.yaml
sed -i "s#192.168.0.0/16#${POD_CIDR}#" custom-resources.yaml
kubectl apply -f custom-resources.yaml



# 4. Success message
echo "✅ First control plane initialized successfully!"
