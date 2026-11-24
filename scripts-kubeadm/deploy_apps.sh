#!/usr/bin/env bash
# deploy_apps.sh - Unified application & GitOps deployment for Kubeadm HA
#
# Usage:
#   ./deploy_apps.sh          - Deploys GitOps engine (ArgoCD) and all platform apps & lab
#   ./deploy_apps.sh verify   - Verifies Traefik ingress & workload health
#   ./deploy_apps.sh status   - Shows status of all pods and ingressroutes
#
set -euo pipefail
source ./00_config.sh
source ./utils.sh

MASTER1="kubeadm-ha-master-1"
MASTER1_IP=$(get_vm_ip "$MASTER1")

ACTION="${1:-all}"

case "$ACTION" in
  all|gitops)
    log "🚀 Deploying all applications via GitOps to $MASTER1..."
    GITOPS_DIR="$(cd "$(dirname "$0")/../gitops" 2>/dev/null && pwd || true)"
    if [ ! -d "$GITOPS_DIR" ]; then
      GITOPS_DIR="$(dirname "$0")/gitops"
    fi
    if [ ! -d "$GITOPS_DIR" ]; then
      fail "GitOps directory not found at $GITOPS_DIR"
    fi

    log "Uploading GitOps manifests to $MASTER1..."
    scp -r -o StrictHostKeyChecking=no "$GITOPS_DIR" "$K8S_USER@$MASTER1_IP:~/"

    log "Bootstrapping ArgoCD and deploying all apps..."
    ssh -o StrictHostKeyChecking=no "$K8S_USER@$MASTER1_IP" "chmod +x ~/gitops/bootstrap/install-argocd.sh && ~/gitops/bootstrap/install-argocd.sh"

    log "✅ All workloads, Traefik routes, and GitOps engines deployed!"
    log "👉 Access URLs via external LB (192.168.1.150):"
    log "   - ArgoCD:    http://argocd.k8s.local"
    log "   - Portfolio: http://portfolio.k8s.local"
    log "   - Dev Lab:   http://dev.k8s.local"
    log "   - Prod Lab:  http://prod.k8s.local"
    log "   - Homepage:  http://homepage.k8s.local"
    log "   - Frigate:   http://frigate.k8s.local"
    ;;

  verify)
    log "Verifying workloads and Traefik Ingress connectivity..."
    scp -o StrictHostKeyChecking=no node-scripts/verify_workloads.sh "$K8S_USER@$MASTER1_IP:~/"
    ssh -o StrictHostKeyChecking=no "$K8S_USER@$MASTER1_IP" "chmod +x ~/verify_workloads.sh && ~/verify_workloads.sh"
    ;;

  status)
    log "Checking status of pods and ingressroutes across cluster..."
    ssh -o StrictHostKeyChecking=no "$K8S_USER@$MASTER1_IP" "kubectl get nodes; echo ''; kubectl get pods -A; echo ''; kubectl get ingressroutes -A"
    ;;

  *)
    echo "Usage: $0 [all | verify | status]"
    echo ""
    echo "Commands:"
    echo "  all      : Deploy all applications (GitOps, Traefik, cert-manager, dev/prod lab, portfolio)"
    echo "  verify   : Run HTTP endpoint verification for all apps"
    echo "  status   : Display pod and ingress status across all namespaces"
    exit 1
    ;;
esac
