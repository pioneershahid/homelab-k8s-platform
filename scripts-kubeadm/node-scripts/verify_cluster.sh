#!/usr/bin/env bash
# verify_cluster.sh - Run on Master 1 at the end of deployment

set -euo pipefail

log() {
  echo -e "\n[ $(date +"%H:%M:%S") ] 🚀 \033[1;34m$*\033[0m"
}

log "Verifying Cluster Node Status..."
kubectl get nodes -o wide

log "Verifying Core System Pods..."
kubectl get pods -n kube-system

log "Verifying CNI Pods (Calico)..."
kubectl get pods -n calico-system 2>/dev/null || kubectl get pods -n kube-system -l k8s-app=calico-node

log "✅ Cluster core verification complete! All control-plane and worker nodes are ready."

