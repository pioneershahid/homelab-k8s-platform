#!/usr/bin/env bash
# join_controlplane.sh - Run on additional control plane nodes (master-2, master-3, etc.)

set -euo pipefail

echo "⏳ Waiting for cloud-init to finish..."
cloud-init status --wait

JOIN_COMMAND=$1

if [ -z "$JOIN_COMMAND" ]; then
  echo "❌ Error: Join command not provided."
  exit 1
fi

echo "⚙️ Joining additional Kubeadm Control Plane node..."

# Execute the join command (it will include --control-plane and --certificate-key)
sudo $JOIN_COMMAND

# Configure kubeconfig for the current user and root
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

echo "✅ Control plane node joined successfully."
