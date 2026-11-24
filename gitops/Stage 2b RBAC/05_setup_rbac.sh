#!/usr/bin/env bash
# 05_setup_rbac.sh - Kubernetes RBAC Setup with Certificate-Based Authentication
# Run after 04_setup_ckad_lab.sh
# This script sets up roles, rolebindings, and the foundation for user certificates

set -euo pipefail

echo "🔐 Setting up Kubernetes RBAC..."

# ============================================================================
# STEP 1: Create Namespaces (if not already done)
# ============================================================================
echo "📦 Creating namespaces..."
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace prod --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace auth --dry-run=client -o yaml | kubectl apply -f -

# ============================================================================
# STEP 2: Create Developer Role in dev namespace
# ============================================================================
echo "👨‍💻 Creating developer role in dev namespace..."
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer
  namespace: dev
rules:
  # Pods
  - apiGroups: [""]
    resources: ["pods", "pods/logs", "pods/exec"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  
  # Services & ConfigMaps
  - apiGroups: [""]
    resources: ["services", "configmaps"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  
  # PersistentVolumeClaims
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch"]
  
  # Deployments
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  
  # Ingresses
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF

# ============================================================================
# STEP 3: Create Viewer Role (read-only) in dev namespace
# ============================================================================
echo "👁️  Creating viewer role in dev namespace..."
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: viewer
  namespace: dev
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/logs", "services", "configmaps"]
    verbs: ["get", "list", "watch"]
  
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets"]
    verbs: ["get", "list", "watch"]
  
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "list", "watch"]
EOF

# ============================================================================
# STEP 4: Create RoleBindings for Groups
# ============================================================================
echo "🔗 Creating role bindings for developer group..."
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developers
  namespace: dev
subjects:
  - kind: Group
    name: developers
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: developer
  apiGroup: rbac.authorization.k8s.io
EOF

echo "🔗 Creating role bindings for viewer group..."
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: viewers
  namespace: dev
subjects:
  - kind: Group
    name: viewers
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: viewer
  apiGroup: rbac.authorization.k8s.io
EOF

# ============================================================================
# STEP 5: Create Auth Namespace Roles
# ============================================================================
echo "🔐 Creating auth-admin role in auth namespace..."
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: auth-admin
  namespace: auth
rules:
  - apiGroups: [""]
    resources: ["*"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  
  - apiGroups: ["apps"]
    resources: ["*"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: auth-admins
  namespace: auth
subjects:
  - kind: Group
    name: auth-admins
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: auth-admin
  apiGroup: rbac.authorization.k8s.io
EOF

# ============================================================================
# STEP 6: Create Cluster-level Roles
# ============================================================================
echo "🌍 Creating cluster-admin binding for k8s-admin group..."
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: k8s-admins
subjects:
  - kind: Group
    name: k8s-admins
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

# ============================================================================
# STEP 7: Create Service Account for automation (optional)
# ============================================================================
echo "🤖 Creating service accounts..."
kubectl create serviceaccount dev-deployer -n dev --dry-run=client -o yaml | kubectl apply -f -
kubectl create rolebinding dev-deployer -n dev --clusterrole=edit --serviceaccount=dev:dev-deployer --dry-run=client -o yaml | kubectl apply -f -

echo ""
echo "✅ RBAC Setup Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Summary of roles and bindings created:"
echo ""
echo "Namespace: dev"
echo "  ✓ Role: developer (full access to pods, deployments, services, etc.)"
echo "  ✓ Role: viewer (read-only access)"
echo "  ✓ RoleBinding: developers -> developer role"
echo "  ✓ RoleBinding: viewers -> viewer role"
echo ""
echo "Namespace: auth"
echo "  ✓ Role: auth-admin (manage auth namespace)"
echo "  ✓ RoleBinding: auth-admins -> auth-admin role"
echo ""
echo "Cluster-level:"
echo "  ✓ ClusterRoleBinding: k8s-admins -> cluster-admin role"
echo ""
echo "Next step: Run 06_generate_user_certs.sh to create user certificates"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
