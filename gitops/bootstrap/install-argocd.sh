#!/usr/bin/env bash
# install-argocd.sh - Bootstrap ArgoCD onto your HA Kubeadm cluster
set -euo pipefail

echo "🚀 Installing ArgoCD into namespace: argocd..."
#Bootstraps ArgoCD into namespace argocd.
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install official stable manifests using server-side apply (avoids annotation size limit)
kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "⏳ Waiting for ArgoCD server pods to be ready..."
kubectl wait --namespace argocd \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=argocd-server \
  --timeout=300s

echo "🔑 Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""

echo "✨ Configuring Platform Secrets from .env (if present)..."
ENV_FILE="$(dirname "$0")/../../.env"
if [ ! -f "$ENV_FILE" ]; then
  ENV_FILE="$(dirname "$0")/.env"
fi

if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a

  # 1. SMB credentials secret for smb.csi.k8s.io
  if [[ -n "${SMB_USER:-}" && -n "${SMB_PASS:-}" ]]; then
    echo "📦 Creating SMB storage secret in kube-system..."
    kubectl create secret generic smbcreds \
      --namespace kube-system \
      --from-literal=username="$SMB_USER" \
      --from-literal=password="$SMB_PASS" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi

  # 2. Docker Hub credentials secret for homelab
  if [[ -n "${DOCKER_USER:-}" && -n "${DOCKER_TOKEN:-}" ]]; then
    echo "📦 Creating dockerhub-secret in homelab..."
    kubectl create namespace homelab --dry-run=client -o yaml | kubectl apply -f -
    kubectl create secret docker-registry dockerhub-secret \
      --docker-server=https://index.docker.io/v1/ \
      --docker-username="$DOCKER_USER" \
      --docker-password="$DOCKER_TOKEN" \
      --docker-email="${DOCKER_EMAIL:-pioneershahid@gmail.com}" \
      -n homelab --dry-run=client -o yaml | kubectl apply -f -
  fi
fi

# Applies storage prerequisites (persistent-volumes.yaml and storageclass-smb.yaml).
echo "✨ Applying Storage Prerequisites & StorageClasses..."
GITOPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$GITOPS_ROOT/platform/storage/persistent-volumes.yaml" ]; then
  kubectl apply -f "$GITOPS_ROOT/platform/storage/persistent-volumes.yaml" || true
fi
if [ -f "$GITOPS_ROOT/platform/storage/storageclass-smb.yaml" ]; then
  kubectl apply -f "$GITOPS_ROOT/platform/storage/storageclass-smb.yaml" || true
fi

#Applies Traefik IngressRoutes, Middlewares, and the CKAD lab.
echo "✨ Applying Traefik Routes & Middlewares..."
if [ -d "$GITOPS_ROOT/platform/traefik" ]; then
  kubectl apply -f "$GITOPS_ROOT/platform/traefik/" || true
fi

echo "✨ Applying CKAD Dev/Prod Lab..."
if [ -d "$GITOPS_ROOT/apps/ckad-lab" ]; then
  kubectl apply -f "$GITOPS_ROOT/apps/ckad-lab/" || true
fi

# Applies the Root Application (root-application.yaml), which triggers ArgoCD to continuously sync all applications:
# Wave -2: cert-manager
# Wave -1: smb-csi-driver
# Wave 0: traefik, monitoring, homepage
# Wave 1: ckad-lab (dev/prod), traefik-routes, frigate, immich, wazuh
# Wave 2: portfolio

echo "✨ Applying Root Application (App-of-Apps)..."
if [ -f "$(dirname "$0")/root-application.yaml" ]; then
  kubectl apply -f "$(dirname "$0")/root-application.yaml"
  echo "✅ Root application submitted to ArgoCD!"
fi
