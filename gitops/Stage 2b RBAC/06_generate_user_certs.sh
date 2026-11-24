#!/usr/bin/env bash
# 06_generate_user_certs.sh - Generate Kubernetes User Certificates and Kubeconfigs
# Run after 05_setup_rbac.sh
# Creates developer (alice, john), viewer (bob, mary), and auth-admin users

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/user-certs"
mkdir -p "$CERTS_DIR"

# Get Kubernetes cluster info
CLUSTER_NAME=$(kubectl config current-context | cut -d'/' -f1 || echo "kubernetes")
API_SERVER=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

echo "🔑 Kubernetes User Certificate Generation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Cluster: $CLUSTER_NAME"
echo "API Server: $API_SERVER"
echo "Certs Directory: $CERTS_DIR"
echo ""

# ============================================================================
# Function to create user certificate
# ============================================================================
create_user_cert() {
  local username=$1
  local group=$2
  
  echo "👤 Creating certificate for user: $username (group: $group)"
  
  # Step 1: Generate private key
  echo "  ├─ Generating private key..."
  openssl genrsa -out "$CERTS_DIR/${username}.key" 4096 2>/dev/null
  chmod 600 "$CERTS_DIR/${username}.key"
  
  # Step 2: Create Certificate Signing Request (CSR)
  echo "  ├─ Creating certificate signing request..."
  openssl req -new \
    -key "$CERTS_DIR/${username}.key" \
    -out "$CERTS_DIR/${username}.csr" \
    -subj "/CN=${username}/O=${group}" \
    2>/dev/null
  
  # Step 3: Encode CSR to base64
  CSR_BASE64=$(cat "$CERTS_DIR/${username}.csr" | base64 | tr -d '\n')
  
  # Step 4: Create Kubernetes CertificateSigningRequest
  echo "  ├─ Submitting to Kubernetes..."
  cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${username}
spec:
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000
  usages:
    - client auth
EOF
  
  # Step 5: Approve the CSR
  echo "  ├─ Approving certificate..."
  kubectl certificate approve "${username}" 2>/dev/null || echo "  │  (Already approved)"
  
  # Step 6: Retrieve and save the certificate
  echo "  ├─ Retrieving signed certificate..."
  sleep 1  # Give server a moment to process
  kubectl get csr "${username}" \
    -o jsonpath='{.status.certificate}' | \
    base64 -d > "$CERTS_DIR/${username}.crt"
  
  # Step 7: Verify certificate
  CERT_CN=$(openssl x509 -in "$CERTS_DIR/${username}.crt" -noout -subject 2>/dev/null | grep -oP 'CN=\K[^,]*')
  CERT_ORG=$(openssl x509 -in "$CERTS_DIR/${username}.crt" -noout -subject 2>/dev/null | grep -oP 'O=\K[^,]*')
  
  if [ "$CERT_CN" == "$username" ] && [ "$CERT_ORG" == "$group" ]; then
    echo "  └─ ✅ Certificate created successfully"
    echo "    Subject: CN=$CERT_CN, O=$CERT_ORG"
  else
    echo "  └─ ❌ Certificate verification failed"
    return 1
  fi
}

# ============================================================================
# Function to create kubeconfig for user
# ============================================================================
create_user_kubeconfig() {
  local username=$1
  local namespace=$2
  local kubeconfig_file="$CERTS_DIR/kubeconfig-${username}"
  
  echo "📝 Creating kubeconfig for $username..."
  
  # Create config file
  kubectl config set-cluster "$CLUSTER_NAME" \
    --server="$API_SERVER" \
    --certificate-authority=<(echo "$CA_DATA" | base64 -d) \
    --kubeconfig="$kubeconfig_file" \
    --embed-certs=true >/dev/null 2>&1 || \
  kubectl config set-cluster "$CLUSTER_NAME" \
    --server="$API_SERVER" \
    --kubeconfig="$kubeconfig_file" \
    --embed-certs=true >/dev/null
  
  kubectl config set-credentials "$username" \
    --client-certificate="$CERTS_DIR/${username}.crt" \
    --client-key="$CERTS_DIR/${username}.key" \
    --embed-certs=true \
    --kubeconfig="$kubeconfig_file" >/dev/null
  
  kubectl config set-context "$username" \
    --cluster="$CLUSTER_NAME" \
    --user="$username" \
    --namespace="$namespace" \
    --kubeconfig="$kubeconfig_file" >/dev/null
  
  kubectl config use-context "$username" \
    --kubeconfig="$kubeconfig_file" >/dev/null
  
  echo "  └─ ✅ Kubeconfig saved: $kubeconfig_file"
}

# ============================================================================
# Create Users
# ============================================================================

echo "📋 Creating users..."
echo ""

# Developer group users
create_user_cert "alice" "developers"
create_user_kubeconfig "alice" "dev"
echo ""

create_user_cert "john" "developers"
create_user_kubeconfig "john" "dev"
echo ""

# Viewer group users
create_user_cert "bob" "viewers"
create_user_kubeconfig "bob" "dev"
echo ""

create_user_cert "mary" "viewers"
create_user_kubeconfig "mary" "dev"
echo ""

# Auth-admin group user
create_user_cert "carol" "auth-admins"
create_user_kubeconfig "carol" "auth"
echo ""

# Cluster-admin user
create_user_cert "sabeen" "k8s-admins"
create_user_kubeconfig "sabeen" "default"
echo ""

# ============================================================================
# Summary and Next Steps
# ============================================================================
echo ""
echo "✅ User Certificate Generation Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📂 Certificates and kubeconfigs saved to: $CERTS_DIR"
echo ""
echo "👥 Users created:"
echo ""
echo "  Developers (full access to dev namespace):"
echo "    • alice   → kubeconfig-alice"
echo "    • john    → kubeconfig-john"
echo ""
echo "  Viewers (read-only access to dev namespace):"
echo "    • bob     → kubeconfig-bob"
echo "    • mary    → kubeconfig-mary"
echo ""
echo "  Auth Admin (full access to auth namespace):"
echo "    • carol   → kubeconfig-carol"
echo ""
echo "  Cluster Admin (full cluster access):"
echo "    • sabeen  → kubeconfig-sabeen"
echo ""
echo "🧪 Testing: Run 07_test_rbac.sh to verify permissions"
echo ""
echo "📖 To use a user kubeconfig:"
echo "    export KUBECONFIG=$CERTS_DIR/kubeconfig-alice"
echo "    kubectl get pods -n dev"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
