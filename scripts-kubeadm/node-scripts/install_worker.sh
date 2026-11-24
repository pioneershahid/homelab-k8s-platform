#!/usr/bin/env bash
# install_worker.sh - Run ONLY on the worker nodes

set -euo pipefail

echo "⏳ Waiting for cloud-init to finish..."
cloud-init status --wait

JOIN_COMMAND=$1

if [ -z "$JOIN_COMMAND" ]; then
  echo "❌ Error: Join command not provided."
  exit 1
fi

echo "⚙️ Joining worker to the Kubeadm cluster..."

# Execute the join command
sudo $JOIN_COMMAND

# Configure kubeconfig for the current user and root
setup_kubeconfig() {
    local target_user=$1
    local target_home=$2
    
    echo "🔑 Configuring kubeconfig for user: $target_user"
    mkdir -p "$target_home/.kube"
    # Note: On workers we uploaded admin.conf to the home dir
    if [ -f ~/admin.conf ]; then
        sudo cp -f ~/admin.conf "$target_home/.kube/config"
        sudo chown "$target_user":"$target_user" "$target_home/.kube/config"
        chmod 600 "$target_home/.kube/config"
    fi
}

# Always setup for root
setup_kubeconfig "root" "/root"

# If run via sudo, setup for the original user too
if [ -n "${SUDO_USER:-}" ]; then
    SUDO_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    setup_kubeconfig "$SUDO_USER" "$SUDO_HOME"
fi

echo "✅ Worker successfully joined the cluster."
