# Stage 2B: Kubernetes RBAC & User Authentication
## Certificate-Based User Access Control

After completing Stage 2 (Authelia Identity Authentication), this stage implements **Kubernetes-native RBAC** with certificate-based user authentication. This is independent from application-level authentication—it protects the Kubernetes API itself.

---

## 🎯 What You'll Learn

1. **Authentication** - Proving who you are to the Kubernetes API
2. **Authorization** - What you're allowed to do (RBAC)
3. **User Management** - Creating and managing Kubernetes users
4. **Group-Based Access** - Using groups for scalable permission management
5. **Namespace Isolation** - Separating access by namespace

---

## 🏗️ Architecture Overview

```
kubectl (user)
    ↓
Client Certificate (CN=alice, O=developers)
    ↓
Kubernetes API Server
    ↓
Authentication: Extracts username & group
    ↓
RBAC Engine: Checks RoleBindings
    ↓
Authorization: Allow or Deny
```

Your users:

```
Alice (developer)  ──┐
John (developer)   ──┼──> developers group ──> dev namespace (create/delete)
                   ──┘

Bob (viewer)       ──┐
Mary (viewer)      ──┼──> viewers group ────> dev namespace (read-only)
                   ──┘

Carol (auth-admin) ──┐
                   └──> auth-admins group ──> auth namespace (full access)

Sabeen (admin)     ──┐
                   └──> k8s-admins group ───> entire cluster (admin)
```

---

## 🚀 Quick Start

### Prerequisites
- Kubernetes cluster running (from `04_setup_ckad_lab.sh`)
- `kubectl` configured with admin access
- OpenSSL installed

### Step 1: Setup RBAC Foundation
```bash
cd scripts-kubeadm
bash 05_setup_rbac.sh
```

This creates:
- Developer role (read/write access in dev namespace)
- Viewer role (read-only access in dev namespace)
- Auth-admin role (full access in auth namespace)
- Group-based role bindings
- Cluster-admin binding

### Step 2: Generate User Certificates
```bash
bash 06_generate_user_certs.sh
```

This creates:
- Private keys and certificates for each user
- Kubeconfig files in `user-certs/` directory
- Users: alice, john (developers), bob, mary (viewers), carol (auth-admin), sabeen (cluster-admin)

### Step 3: Test Permissions
```bash
bash 07_test_rbac.sh
```

This validates:
- Users can access what they should
- Users cannot access what they shouldn't
- Group-based permissions work correctly

---

## 📋 User Directory

After running the scripts, you'll have kubeconfigs in `scripts-kubeadm/user-certs/`:

| User | Group | Access | Kubeconfig |
|------|-------|--------|-----------|
| alice | developers | Create/delete in dev NS | kubeconfig-alice |
| john | developers | Create/delete in dev NS | kubeconfig-john |
| bob | viewers | Read-only in dev NS | kubeconfig-bob |
| mary | viewers | Read-only in dev NS | kubeconfig-mary |
| carol | auth-admins | Full access in auth NS | kubeconfig-carol |
| sabeen | k8s-admins | Cluster admin | kubeconfig-sabeen |

---

## 💻 Using User Kubeconfigs

### Switch to a User Context
```bash
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-alice
kubectl get pods -n dev
```

### Check Your Identity
```bash
kubectl auth whoami
```

Output:
```
ATTRIBUTE   VALUE
Username    alice
Groups      [developers system:authenticated]
```

### Create Multiple Kubeconfig Sessions
```bash
# Terminal 1 - Alice (developer)
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-alice
kubectl get pods -n dev

# Terminal 2 - Bob (viewer)
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-bob
kubectl get pods -n dev
```

---

## 🔍 Testing Permissions

### Test if User CAN Do Something
```bash
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-alice
kubectl auth can-i create deployments -n dev   # Should be: yes
kubectl auth can-i delete pods -n dev          # Should be: yes
kubectl auth can-i get pods -n auth            # Should be: no
```

### Verify Actual Operations
```bash
# Alice (developer) - should work
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-alice
kubectl run test-pod --image=nginx -n dev

# Bob (viewer) - should fail
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-bob
kubectl delete pod test-pod -n dev             # Forbidden

# Carol (auth-admin) - can access auth namespace
export KUBECONFIG=scripts-kubeadm/user-certs/kubeconfig-carol
kubectl get pods -n auth                       # Works
kubectl get pods -n dev                        # Forbidden
```

---

## 🔧 How Certificate Authentication Works

### 1. User Generates Private Key
```bash
openssl genrsa -out alice.key 4096
```

### 2. User Creates Certificate Signing Request (CSR)
The CSR contains:
- **CN (Common Name)** = username (e.g., alice)
- **O (Organization)** = group (e.g., developers)

```bash
openssl req -new \
  -key alice.key \
  -out alice.csr \
  -subj "/CN=alice/O=developers"
```

Kubernetes interprets this as:
- Username: `alice`
- Groups: `[developers]`

### 3. Kubernetes Approves and Signs
The CertificateSigningRequest gets approved by the cluster admin, and Kubernetes CA signs it:

```bash
kubectl certificate approve alice
kubectl get csr alice -o jsonpath='{.status.certificate}' | base64 -d > alice.crt
```

### 4. User Creates Kubeconfig
The kubeconfig contains:
- Kubernetes API server address
- User's certificate
- User's private key
- Cluster CA certificate

### 5. User Authenticates to API Server
```bash
export KUBECONFIG=kubeconfig-alice
kubectl get pods -n dev
```

The flow:
1. kubectl sends certificate and key
2. API server verifies against cluster CA
3. API server extracts: `username=alice, groups=developers`
4. RBAC evaluates: "Can developers create pods in dev namespace?"
5. If yes: command executes; if no: Forbidden error

---

## 📚 Understanding RBAC

### The RBAC Model

```
User → authenticated as → Group → RoleBinding → Role → Permissions
alice ─────────────────→ developers ──→ RoleBinding ──→ developer Role
                                        (in dev NS)
                                            ↓
                                    "get/list/watch/create/update/patch/delete
                                     pods, deployments, services, etc."
```

### Role vs ClusterRole

**Role** (namespace-scoped):
- Permissions apply within a specific namespace
- Created for `dev`, `auth` namespaces
- User can only access that namespace

**ClusterRole** (cluster-scoped):
- Permissions apply across entire cluster
- Example: `cluster-admin` can access all namespaces, nodes, secrets, etc.

### RoleBinding vs ClusterRoleBinding

**RoleBinding**:
- Binds subjects (users/groups) to Role
- Confined to one namespace

**ClusterRoleBinding**:
- Binds subjects (users/groups) to ClusterRole
- Works across entire cluster

### Example: Developer Role in dev Namespace

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer
  namespace: dev
rules:
  - apiGroups: [""]
    resources: ["pods", "services"]
    verbs: ["get", "list", "watch", "create", "delete"]
  
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "delete"]
```

This says: In the `dev` namespace, allow these verbs on these resources.

---

## 🛡️ Security Best Practices

### 1. Don't Give Cluster-Admin Lightly
```bash
# ❌ DON'T DO THIS
kind: ClusterRoleBinding
subjects:
  - kind: Group
    name: everyone
roleRef:
  kind: ClusterRole
  name: cluster-admin

# ✅ DO THIS INSTEAD
kind: ClusterRoleBinding
subjects:
  - kind: Group
    name: k8s-admins       # Only admins
roleRef:
  kind: ClusterRole
  name: cluster-admin
```

### 2. Use Namespace Isolation
```bash
# Developers can access dev, but not prod or auth
Alice → developers → dev namespace only
```

### 3. Don't Give Access to Secrets Unnecessarily
Most developers don't need to read secrets. If they do, be explicit:

```yaml
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get"]
  resourceNames: ["app-config"]  # Only specific secret
```

### 4. Use Read-Only for Low-Trust Users
```yaml
# Viewers - read-only
rules:
  - apiGroups: [""]
    resources: ["pods", "services"]
    verbs: ["get", "list", "watch"]  # NO create/delete/patch
```

### 5. Separate Admins by Namespace
```
Alice  ─┐
        ├─> dev-admins   ─> dev namespace admin
John   ─┘

Carol  ─┐
        ├─> auth-admins  ─> auth namespace admin
Dave   ─┘

Sabeen ─> k8s-admins     ─> cluster admin (only one person!)
```

---

## 🧠 Common Scenarios

### Scenario 1: Developer Joins Your Team
1. Generate certificate for new user
2. Add to `developers` group
3. `developers` group already has role binding
4. New user immediately has access to dev namespace

### Scenario 2: Promote Developer to Admin
1. Update their certificate group: `O=k8s-admins`
2. Regenerate certificate with new group
3. Update kubeconfig
4. User now has cluster-admin access

### Scenario 3: Temporarily Give Access to Test Namespace
1. Create new RoleBinding for `developers` group in `test` namespace
2. Developers can now access both `dev` and `test`

### Scenario 4: Remove User Access
1. Delete their certificate
2. Delete their kubeconfig
3. User loses all access

---

## 🐛 Troubleshooting

### "Forbidden" Error When User Tries Action
1. Check user's group:
   ```bash
   export KUBECONFIG=kubeconfig-alice
   kubectl auth whoami
   ```

2. Check what user can do:
   ```bash
   kubectl auth can-i create pods -n dev
   ```

3. List role bindings:
   ```bash
   kubectl get rolebindings -n dev
   kubectl describe rolebinding developers -n dev
   ```

4. Check the role:
   ```bash
   kubectl describe role developer -n dev
   ```

### "Unable to Establish Connection" 
- Check kubeconfig has correct API server address:
  ```bash
  kubectl config view
  ```
- Verify certificate is valid:
  ```bash
  openssl x509 -in user-certs/alice.crt -text -noout
  ```

### Certificate Expired
- Regenerate: `bash 06_generate_user_certs.sh`
- Update kubeconfig: `export KUBECONFIG=user-certs/kubeconfig-alice`

---

## 📖 File Reference

### Created by 05_setup_rbac.sh
- Roles: `developer`, `viewer`, `auth-admin` 
- RoleBindings: `developers`, `viewers`, `auth-admins`
- ClusterRoleBinding: `k8s-admins`

### Created by 06_generate_user_certs.sh
- `user-certs/alice.{key,crt,csr}`
- `user-certs/kubeconfig-alice`
- Similar for john, bob, mary, carol, sabeen

### Created by 07_test_rbac.sh
- Validates all permissions
- Tests actual kubectl commands
- Reports pass/fail status

---

## 🎓 What's Next?

After mastering certificate-based RBAC:

1. **OIDC Integration** (Future Stage 2C)
   - Replace certificates with tokens from Authelia
   - Centralize identity management
   - Easier for users (no certificate management)

2. **Network Policies**
   - Pod-to-pod network isolation
   - Requires CNI support (Calico recommended)

3. **Pod Security Policy / Pod Security Standards**
   - Restrict what containers can run
   - Prevent privileged containers, etc.

4. **Advanced RBAC**
   - Custom roles for specific workflows
   - Aggregated ClusterRoles

---

## 📚 Key Concepts Summary

| Concept | Purpose |
|---------|---------|
| **Certificate** | Proves identity to API server |
| **User** | Individual who can authenticate |
| **Group** | Collection of users with same role |
| **Role/ClusterRole** | Set of permissions |
| **RoleBinding/ClusterRoleBinding** | Links subjects to roles |
| **Namespace** | Scope of access |
| **Kubeconfig** | File with API server, certs, contexts |

---

## ✅ Checklist

After completing Stage 2B:

- [ ] Run `05_setup_rbac.sh` - RBAC foundation created
- [ ] Run `06_generate_user_certs.sh` - User certificates created
- [ ] Run `07_test_rbac.sh` - All tests passed
- [ ] Test switching between user kubeconfigs
- [ ] Verify developers can create deployments in dev
- [ ] Verify viewers can only read in dev
- [ ] Verify admins have cluster access
- [ ] Understand certificate-based authentication
- [ ] Understand RBAC model (users → groups → roles)

---

## 🔗 Related Files

- **Stage 2A**: [Authelia Setup](../Kubernetes_Stage_2_Identity_Authentication_README.md)
- **Stage 1**: Kubeadm cluster setup
- **CKAD Lab**: [04_setup_ckad_lab.sh](./04_setup_ckad_lab.sh)

---

**Created:** 2024  
**Purpose:** Learn Kubernetes authentication and RBAC in a lab environment  
**Next Stage:** OIDC integration with Authelia for centralized identity
