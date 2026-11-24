#!/usr/bin/env bash
# verify_workloads.sh - Verify optional Ingress Controller and CKAD Lab workloads

set -euo pipefail

log() {
  echo -e "\n[ $(date +"%H:%M:%S") ] 🚀 \033[1;34m$*\033[0m"
}

log "Verifying Ingress Controller (Traefik)..."
kubectl get pods -n traefik || true
kubectl get svc -n traefik || true

log "Verifying Multi-tier Workloads..."
log "Namespace: DEV"
kubectl get all -n dev || true
log "Namespace: PROD"
kubectl get all -n prod || true

log "Testing Ingress Connectivity (Internal Check)..."
WORKER_IP=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")

if [ -z "$WORKER_IP" ]; then
  echo "⚠️  Could not determine worker node IP. Skipping HTTP check."
  exit 0
fi

echo "Testing Traefik Ingress Connectivity..."
DEV_OK=0
PROD_OK=0
PORTFOLIO_OK=0

for i in {1..5}; do
  echo "Attempt $i/5..."
  
  if curl -s -m 5 -H "Host: dev.k8s.local" "http://$WORKER_IP:30080" | grep -q "Welcome to nginx"; then
    echo "✅ DEV Ingress Working (http://dev.k8s.local)"
    DEV_OK=1
  fi
  
  if curl -s -m 5 -H "Host: prod.k8s.local" "http://$WORKER_IP:30080" | grep -q "Welcome to nginx"; then
    echo "✅ PROD Ingress Working (http://prod.k8s.local)"
    PROD_OK=1
  fi

  if curl -s -I -m 5 -H "Host: portfolio.k8s.local" "http://$WORKER_IP:30080" | grep -q "HTTP/1.1 200"; then
    echo "✅ PORTFOLIO Ingress Working (http://portfolio.k8s.local)"
    PORTFOLIO_OK=1
  fi
  
  if [ $DEV_OK -eq 1 ] && [ $PROD_OK -eq 1 ]; then
    log "✅ Core Ingress routes verified!"
    break
  fi
  
  sleep 5
done

log "✅ Workload verification complete!"
