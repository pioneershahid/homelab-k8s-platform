#!/usr/bin/env bash
# install_prereqs.sh - Install container runtime and k8s tools (Run on ALL nodes)
DOCKER_USER=${1:-""}
DOCKER_TOKEN=${2:-""}

set -euo pipefail

echo "⏳ Waiting for cloud-init to finish..."
cloud-init status --wait

echo "⏳ Waiting for apt lock..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  sleep 5
done

echo "⚙️ Installing prerequisites..."

# 1. Update and install basic packages
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl

# 2. Set up kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# 3. Set sysctl parameters
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# 4. Install containerd
sudo apt-get install -y containerd

# 5. Configure containerd with SystemdCgroup and Docker Auth
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null

# Enable SystemdCgroup for containerd CRI plugin (v1 and v2 compatible)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Ensure CRI plugin is NOT disabled
sudo sed -i 's/disabled_plugins = \["cri"\]/disabled_plugins = \[\]/' /etc/containerd/config.toml

if [ -n "$DOCKER_USER" ] && [ -n "$DOCKER_TOKEN" ]; then
    echo "🐳 Configuring Docker Hub authentication..."
    cat <<EOF | sudo tee -a /etc/containerd/config.toml

[plugins."io.containerd.grpc.v1.cri".registry.configs."docker.io".auth]
  username = "$DOCKER_USER"
  password = "$DOCKER_TOKEN"
EOF
fi

sudo systemctl daemon-reload
sudo systemctl enable --now containerd
sudo systemctl restart containerd

# Verify containerd CRI socket is responsive before proceeding
echo "⏳ Waiting for containerd socket..."
for i in {1..10}; do
  if [ -S /run/containerd/containerd.sock ]; then
    break
  fi
  sleep 2
done

# 6. Install Kubernetes packages (pin to stable minor release)
KUBE_VERSION="v1.31"
KUBE_LATEST=$(curl -L -s https://dl.k8s.io/release/stable.txt | awk 'BEGIN { FS="." } { printf "%s.%s", $1, $2 }')
# If stable is accessible and reasonable, use KUBE_LATEST, else default to KUBE_VERSION
KUBE_REPO="${KUBE_LATEST:-$KUBE_VERSION}"

sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBE_REPO}/deb/Release.key" | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg || true

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBE_REPO}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl cri-tools
sudo apt-mark hold kubelet kubeadm kubectl

# 7. Configure crictl
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

# 8. Configure Kubelet extra args
# We extract the PRIMARY_IP that was set by cloud-init
source /etc/environment
cat <<EOF | sudo tee /etc/default/kubelet
KUBELET_EXTRA_ARGS='--node-ip ${PRIMARY_IP}'
EOF

sudo systemctl restart kubelet

echo "✅ Prerequisites installed successfully."
