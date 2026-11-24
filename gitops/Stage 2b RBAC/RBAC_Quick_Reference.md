# Kubernetes RBAC Quick Reference
## Common Commands & Operations

---

## 🚀 Quick Setup (All-in-One)

```bash
cd scripts-kubeadm

# 1. Setup RBAC foundation
bash 05_setup_rbac.sh

# 2. Generate user certificates
bash 06_generate_user_certs.sh

# 3. Verify everything works
bash 07_test_rbac.sh
```

---

## 👤 Using Different Users

### Switch to User Context
```bash
# Alice (developer)
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-alice

# Bob (viewer)
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-bob

# Carol (auth-admin)
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-carol

# Sabeen (cluster-admin)
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-sabeen

# Back to admin
unset KUBECONFIG  # or: export KUBECONFIG=~/.kube/config
```

### Check Your Identity
```bash
kubectl auth whoami
```

---

## ✅ Permission Testing

### Test Single Permission
```bash
# Can alice create pods in dev?
kubectl auth can-i create pods -n dev

# Can bob delete deployments in dev?
kubectl auth can-i delete deployments -n dev

# Can carol access auth namespace?
kubectl auth can-i get pods -n auth

# Can carol access dev namespace?
kubectl auth can-i get pods -n dev
```

### Test All Verbs for User
```bash
# What can alice do with pods in dev?
kubectl auth can-i --list -n dev
```

### Test Actual Operations
```bash
# Alice tries to create pod (should work)
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-alice
kubectl run test --image=nginx -n dev

# Bob tries to delete pod (should be denied)
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-bob
kubectl delete pod test -n dev  # Error: Forbidden
```

---

## 📋 Listing RBAC Resources

### View All Roles in Namespace
```bash
kubectl get roles -n dev
kubectl describe role developer -n dev
```

### View All RoleBindings
```bash
kubectl get rolebindings -n dev
kubectl describe rolebinding developers -n dev
```

### View All ClusterRoleBindings
```bash
kubectl get clusterrolebindings
kubectl describe clusterrolebinding k8s-admins
```

### View All ClusterRoles
```bash
kubectl get clusterroles
kubectl describe clusterrole cluster-admin
```

---

## 🔑 Certificate Management

### View User Certificate
```bash
# Check certificate subject and validity
openssl x509 -in scripts-kubeadm/user-certs/alice.crt -text -noout

# Check expiration
openssl x509 -in scripts-kubeadm/user-certs/alice.crt -noout -dates
```

### View Kubernetes CSR Status
```bash
# List all certificate signing requests
kubectl get csr

# Details of one CSR
kubectl describe csr alice

# Approve a CSR manually
kubectl certificate approve alice

# Deny a CSR
kubectl certificate deny bob
```

### Verify Kubeconfig
```bash
kubectl config view --kubeconfig=scripts-kubeadm/user-certs/kubeconfig-alice
```

---

## 👥 User Management Operations

### List All Users (Certificates)
```bash
ls -la scripts-kubeadm/user-certs/*.crt | awk '{print $NF}' | xargs -I {} basename {} .crt
```

### Check User's Groups
```bash
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-alice
kubectl auth whoami
# Output: USERNAME alice, GROUPS [developers system:authenticated]
```

### List Users in a Group
```bash
# Kubernetes doesn't have built-in group listing
# But you can check rolebindings:
kubectl get rolebinding developers -n dev -o yaml
```

---

## 📝 Creating Additional Roles

### Create New Role
```bash
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tester
  namespace: dev
rules:
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch"]
EOF
```

### Bind Role to Group
```bash
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: testers
  namespace: dev
subjects:
  - kind: Group
    name: testers
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: tester
  apiGroup: rbac.authorization.k8s.io
EOF
```

### Create New User with Group
```bash
# 1. Generate cert with new group
openssl genrsa -out /tmp/newuser.key 4096
openssl req -new \
  -key /tmp/newuser.key \
  -out /tmp/newuser.csr \
  -subj "/CN=newuser/O=testers"

# 2. Submit to Kubernetes
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: newuser
spec:
  request: $(cat /tmp/newuser.csr | base64 | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: 31536000
  usages:
    - client auth
EOF

# 3. Approve and retrieve
kubectl certificate approve newuser
kubectl get csr newuser -o jsonpath='{.status.certificate}' | base64 -d > /tmp/newuser.crt

# 4. Create kubeconfig
kubectl config set-cluster kubernetes --server=<API_SERVER> --kubeconfig=/tmp/kubeconfig-newuser
kubectl config set-credentials newuser --client-certificate=/tmp/newuser.crt --client-key=/tmp/newuser.key --kubeconfig=/tmp/kubeconfig-newuser
kubectl config set-context newuser --cluster=kubernetes --user=newuser --namespace=dev --kubeconfig=/tmp/kubeconfig-newuser
kubectl config use-context newuser --kubeconfig=/tmp/kubeconfig-newuser
```

---

## 🔍 Debugging RBAC Issues

### User Gets "Forbidden" Error

**Step 1:** Check user's identity
```bash
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-alice
kubectl auth whoami
```

**Step 2:** Check what user is allowed to do
```bash
kubectl auth can-i get pods -n dev
kubectl auth can-i delete pods -n dev
```

**Step 3:** Examine RBAC chain
```bash
# Get user's group (from certificate)
openssl x509 -in scripts-kubeadm/user-certs/alice.crt -noout -subject
# Output: subject=CN = alice, O = developers

# Check if group has rolebinding
kubectl get rolebindings -n dev -o json | grep -A5 developers

# Check if role has needed permission
kubectl describe role developer -n dev
```

### User Can't Access Namespace

```bash
# Permissions are namespace-specific
# Check all rolebindings in the namespace
kubectl get rolebindings -n <namespace>
kubectl get clusterrolebindings | grep <username>

# Create new rolebinding if needed
kubectl create rolebinding <name> -n <namespace> \
  --clusterrole=edit \
  --group=<group>
```

### Certificate Issues

```bash
# Check certificate validity
openssl x509 -in alice.crt -noout -text

# Check if expired
openssl x509 -in alice.crt -noout -dates

# Check CSR status
kubectl get csr alice -o yaml
kubectl describe csr alice

# Delete and regenerate if needed
kubectl delete csr alice
# Then run 06_generate_user_certs.sh again
```

---

## 📊 Permission Matrix Reference

| User | Dev Namespace | Auth Namespace | Cluster |
|------|---|---|---|
| alice (developer) | ✅ Create/Read/Delete | ❌ | ❌ |
| bob (viewer) | ✅ Read-only | ❌ | ❌ |
| carol (auth-admin) | ❌ | ✅ Create/Read/Delete | ❌ |
| sabeen (admin) | ✅ Full | ✅ Full | ✅ Full |

---

## 🎯 Most Common Operations

```bash
# 1. Setup everything
bash scripts-kubeadm/05_setup_rbac.sh
bash scripts-kubeadm/06_generate_user_certs.sh
bash scripts-kubeadm/07_test_rbac.sh

# 2. Switch to alice (developer)
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-alice

# 3. Check identity
kubectl auth whoami

# 4. See what you can do
kubectl auth can-i --list -n dev

# 5. Deploy something
kubectl create deployment test --image=nginx -n dev

# 6. Switch to bob (viewer)
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-bob

# 7. Try to delete (should fail)
kubectl delete deployment test -n dev  # Forbidden

# 8. Switch back to admin
unset KUBECONFIG

# 9. Check all users
kubectl get csr
```

---

## 🔐 Security Reminders

✅ **DO:**
- Use groups for scalability
- Give minimum required permissions
- Review permissions regularly
- Use namespace isolation
- Audit who has cluster-admin

❌ **DON'T:**
- Give everyone cluster-admin
- Put users in multiple high-privilege groups
- Store kubeconfigs insecurely
- Forget to approve/deny CSRs
- Ignore "Forbidden" errors in logs

---

## 🎓 Learning Path

1. **Read** [Stage_2B_RBAC_User_Authentication.md](./Stage_2B_RBAC_User_Authentication.md)
2. **Run** setup scripts
3. **Test** permissions with different users
4. **Break things** intentionally to learn
5. **Review** RBAC objects with `kubectl describe`
6. **Extend** by creating new roles/users

---

**Last Updated:** 2024  
**Applies To:** Kubernetes clusters using certificate-based authentication  
**See Also:** [Stage 2B Documentation](./Stage_2B_RBAC_User_Authentication.md)
