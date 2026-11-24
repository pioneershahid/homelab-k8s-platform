# Kubernetes Stage 2: Identity & Authentication (Authelia + Traefik)
## Quick Reference & Deployment Guide

---

## 📋 Status: COMPLETE & WORKING

**Current Stack:**
- Kubernetes kubeadm cluster (5 nodes + LB)
- Traefik 3.7.1 Ingress Controller
- Authelia 4.39.20 Authentication
- Redis session backend
- File-based user authentication
- Wildcard TLS certificates (cert-manager)
- Protected sample NGINX application

**Known Issue:** LDAP/OpenLDAP not reliable; using file-based auth instead.

---

## 🏗️ Architecture at a Glance

```
                    Internet / LAN
                          |
                   192.168.1.150 (LB)
                          |
                       Traefik
                          |
        +-------------------+-------------------+
        |                                       |
   auth.k8s.local                         dev.k8s.local
   (Authelia Portal)                    (Protected App)
        |                                       |
   [No ForwardAuth]              [ForwardAuth Middleware]
        |                                       |
    Authelia                              Authelia
     Check                                Validate
        |                                       |
   Login Form                            NGINX (if auth OK)
```

**Key Point:** `auth.k8s.local` must NOT use ForwardAuth (creates auth loop). It's the authentication endpoint itself.

---

## 🚀 Quick Setup Checklist

### Prerequisites
```bash
kubectl get nodes -o wide          # Verify cluster running
kubectl get namespaces             # Verify Kubernetes access
```

### 1. Namespace & Redis
```bash
kubectl create namespace auth

# Apply Redis
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: auth
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        args:
          - redis-server
          - --requirepass
          - $(REDIS_PASSWORD)
        env:
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: authelia-redis-secret
              key: session.redis.password.txt
        ports:
        - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: auth
spec:
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
EOF

# Verify
kubectl get pods -n auth
kubectl wait --for=condition=Ready pod -l app=redis -n auth --timeout=300s
```

### 2. Create Secrets
```bash
# Session encryption key
openssl rand -hex 32  # Copy output
kubectl create secret generic authelia-session-secret \
  -n auth \
  --from-literal=session.encryption.key='PASTE_HERE'

# Storage encryption key
openssl rand -hex 32  # Copy output
kubectl create secret generic authelia-storage-secret \
  -n auth \
  --from-literal=storage.encryption.key='PASTE_HERE'

# Redis password
openssl rand -hex 32  # Copy output
kubectl create secret generic authelia-redis-secret \
  -n auth \
  --from-literal=session.redis.password.txt='PASTE_HERE'
```

### 3. Create User Database
```bash
# Generate password hash
docker run --rm authelia/authelia:4.39.20 \
  authelia crypto hash generate argon2 --password 'YourPassword123'
# Copy the hash output

# Create users_database.yml
cat > users_database.yml <<'EOF'
users:
  admin:
    disabled: false
    displayname: "Administrator"
    password: "PASTE_ARGON2_HASH_HERE"
    email: "admin@k8s.local"
    groups:
      - admins
      - dev
  
  developer:
    disabled: false
    displayname: "Developer"
    password: "PASTE_ARGON2_HASH_HERE"
    email: "developer@k8s.local"
    groups:
      - developers
      - dev
EOF

# Create ConfigMap
kubectl create configmap authelia-users \
  -n auth \
  --from-file=users_database.yml=users_database.yml
```

### 4. Install Authelia (Helm)
```bash
helm repo add authelia https://charts.authelia.com
helm repo update

cat > authelia-values.yaml <<'EOF'
image:
  tag: "4.39.20"

service:
  type: ClusterIP
  port: 80

pod:
  kind: Deployment
  replicas: 1

  extraVolumes:
    - name: users-database
      configMap:
        name: authelia-users
    - name: authelia-data
      emptyDir: {}

  extraVolumeMounts:
    - name: users-database
      mountPath: /config/users_database.yml
      subPath: users_database.yml
      readOnly: true
    - name: authelia-data
      mountPath: /data

secret:
  additionalSecrets:
    authelia-session-secret: {}
    authelia-redis-secret: {}
    authelia-storage-secret: {}

configMap:
  disabled: false
  
  server:
    port: 9091

  authentication_backend:
    file:
      enabled: true
      path: /config/users_database.yml
      watch: true

  access_control:
    default_policy: deny
    rules:
      - domain: auth.k8s.local
        policy: bypass
      - domain: dev.k8s.local
        policy: one_factor

  session:
    name: authelia_session
    same_site: lax
    expiration: "1 hour"
    inactivity: "5 minutes"
    remember_me: "1 month"

    encryption_key:
      secret_name: authelia-session-secret
      path: session.encryption.key

    cookies:
      - domain: k8s.local
        subdomain: auth
        default_redirection_url: https://dev.k8s.local
        same_site: lax
        expiration: "1 hour"
        inactivity: "5 minutes"

    redis:
      enabled: true
      deploy: false
      host: redis.auth.svc.cluster.local
      port: 6379
      password:
        secret_name: authelia-redis-secret
        path: session.redis.password.txt
      database_index: 0

  storage:
    encryption_key:
      secret_name: authelia-storage-secret
      path: storage.encryption.key
    local:
      enabled: true
      path: /data/db.sqlite3

  notifier:
    filesystem:
      enabled: true
      filename: /data/notification.txt
EOF

helm install authelia authelia/authelia \
  --namespace auth \
  --version 0.11.6 \
  -f authelia-values.yaml

kubectl wait --for=condition=Ready pod -l app=authelia -n auth --timeout=300s
```

### 5. Create Traefik Middleware (ForwardAuth)
```bash
cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authelia
  namespace: dev
spec:
  forwardAuth:
    address: http://authelia.auth.svc.cluster.local/api/authz/forward-auth
    trustForwardHeader: true
    authResponseHeaders:
      - Remote-User
      - Remote-Groups
      - Remote-Name
      - Remote-Email
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
  namespace: dev
spec:
  redirectScheme:
    scheme: https
    permanent: true
EOF

kubectl get middleware -n dev
```

### 6. Test Authentication
```bash
# Test Authelia portal
curl -k -I https://auth.k8s.local
# Expected: HTTP/2 200

# Test Authelia endpoint
kubectl run auth-test -n dev --rm -it --restart=Never --image=curlimages/curl:8.12.1 -- \
  curl -i -H 'X-Forwarded-Method: GET' \
       -H 'X-Forwarded-Proto: https' \
       -H 'X-Forwarded-Host: dev.k8s.local' \
       -H 'X-Forwarded-URI: /' \
       http://authelia.auth.svc.cluster.local/api/authz/forward-auth
# Expected: HTTP/1.1 302 Found with redirect to auth.k8s.local

# Test with browser
# 1. Open https://dev.k8s.local (InPrivate/Incognito)
# 2. Redirect to https://auth.k8s.local
# 3. Login with user credentials
# 4. Redirect back to https://dev.k8s.local with NGINX content
```

---

## 🔧 Common Operations

### Update User Database
```bash
# Edit file
nano users_database.yml

# Generate new password hash
docker run --rm authelia/authelia:4.39.20 \
  authelia crypto hash generate argon2 --password 'NewPassword'

# Update ConfigMap
kubectl create configmap authelia-users \
  -n auth \
  --from-file=users_database.yml=users_database.yml \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart Authelia to reload
kubectl rollout restart deployment/authelia -n auth
```

### Check Logs
```bash
# Authelia logs
kubectl logs -n auth deploy/authelia --tail=50
kubectl logs -n auth deploy/authelia -f  # Live

# Traefik logs (search for errors)
kubectl logs -n traefik deploy/traefik --tail=50
kubectl logs -n traefik deploy/traefik | grep -i authelia
```

### Verify Redis Connection
```bash
# Get Redis password
REDIS_PW=$(kubectl get secret authelia-redis-secret -n auth \
  -o jsonpath='{.data.session\.redis\.password\.txt}' | base64 -d)

# Test connection
kubectl exec -n auth deploy/redis -- \
  redis-cli -a "$REDIS_PW" ping
# Expected: PONG
```

### Verify Session Storage
```bash
REDIS_PW=$(kubectl get secret authelia-redis-secret -n auth \
  -o jsonpath='{.data.session\.redis\.password\.txt}' | base64 -d)

# List all keys
kubectl exec -n auth deploy/redis -- \
  redis-cli -a "$REDIS_PW" KEYS '*'

# Check session TTL
kubectl exec -n auth deploy/redis -- \
  redis-cli -a "$REDIS_PW" TTL authelia_session:*
```

---

## 🔐 Security Quick Check

```bash
# 1. Verify TLS certificate
kubectl describe certificate -n dev wildcard-k8s-local
# Should show: Approved, Ready = True

# 2. Verify secret exists
kubectl get secret -n dev wildcard-k8s-local-tls
# Should show as created

# 3. Verify Authelia is running
kubectl get pods -n auth
# Should show authelia and redis both Running

# 4. Verify middleware exists
kubectl get middleware -n dev
# Should show authelia and redirect-https

# 5. Verify ingress has middleware annotation
kubectl get ingress -n dev frontend-ingress -o yaml | grep -A2 "middlewares"
# Should show: dev-authelia@kubernetescrd,dev-redirect-https@kubernetescrd
```

---

## 🚨 Troubleshooting

### "Forbidden" / "WRONGPASS" in Authelia logs
```bash
# Check Redis password matches
kubectl logs -n auth deploy/authelia | grep -i "wrong\|password\|redis"

# Get the configured password
kubectl get secret authelia-redis-secret -n auth -o jsonpath='{.data.session\.redis\.password\.txt}' | base64 -d

# Verify Redis accepts it
REDIS_PW='<paste-password-here>'
kubectl exec -n auth deploy/redis -- redis-cli -a "$REDIS_PW" ping
```

### "middleware does not exist"
```bash
# Verify middleware created
kubectl get middleware -n dev

# Check Traefik can see it
kubectl logs -n traefik deploy/traefik | grep -i middleware

# If missing, recreate:
kubectl apply -f <middleware-yaml>

# Verify ingress annotation is correct format:
# traefik.ingress.kubernetes.io/router.middlewares: dev-authelia@kubernetescrd
```

### Authelia CrashLoopBackOff
```bash
# Check logs
kubectl logs -n auth deploy/authelia -p  # Previous log

# Common causes:
# - Redis password mismatch → fix secret and restart
# - User file not mounted → check ConfigMap exists
# - Session secret missing → create secret

kubectl rollout restart deployment/authelia -n auth
```

### User Can't Login
```bash
# Verify user exists in ConfigMap
kubectl get configmap authelia-users -n auth -o yaml | grep -A5 'users:'

# Verify password was hashed correctly
# (Test with auth.k8s.local login)

# Check Authelia logs for clues
kubectl logs -n auth deploy/authelia | grep -i "auth\|user\|error"
```

### Session Not Persisting Across Domains
```bash
# Verify cookie domain is correct
kubectl get secret authelia-session-secret -n auth -o yaml

# Cookies should be set for .k8s.local (with leading dot)
# Check browser DevTools → Storage → Cookies → authelia_session

# If cookie is missing, check Authelia config:
kubectl logs -n auth deploy/authelia | grep -i "cookie\|session"
```

---

## 📊 Architecture Components Reference

| Component | Namespace | Type | Purpose |
|-----------|-----------|------|---------|
| Authelia | auth | Deployment | Identity & authentication |
| Redis | auth | Deployment | Session storage |
| authelia-users | auth | ConfigMap | User database (file) |
| authelia-session-secret | auth | Secret | Session encryption key |
| authelia-redis-secret | auth | Secret | Redis password |
| authelia-storage-secret | auth | Secret | Storage encryption key |
| authelia (Middleware) | dev | Middleware | ForwardAuth for Traefik |
| redirect-https (Middleware) | dev | Middleware | HTTP → HTTPS redirect |
| frontend-ingress | dev | Ingress | Routes to NGINX |
| wildcard-k8s-local | dev | Certificate | TLS for *.k8s.local |

---

## 📚 Common URLs

```
https://auth.k8s.local        ← Authelia login portal
https://dev.k8s.local         ← Protected application (redirect if not auth)
https://dev.k8s.local/logout  ← Logout endpoint
```

---

## 🎯 Key Decisions Made

1. **File-based Authentication:** Simple, works reliably, good for homelab
2. **Redis Backend:** Shared session storage for scalability
3. **Single Ingress Strategy:** All traffic through Traefik + ForwardAuth
4. **Wildcard Certificates:** Covers all subdomains under k8s.local
5. **Bypass for auth.k8s.local:** Prevents authentication loop

---

## ✅ Completion Checklist

- [x] Redis deployed and verified
- [x] Authelia deployed with file authentication
- [x] Session secrets created
- [x] Redis password configured
- [x] Traefik ForwardAuth middleware created
- [x] auth.k8s.local accessible (bypass policy)
- [x] dev.k8s.local requires authentication
- [x] Login redirects work
- [x] Session persists across requests
- [x] Logout clears session
- [x] TLS working for all domains

---

## 🔄 Helm Upgrade Procedure

Always follow this order:

```bash
# Step 1: Backup
helm get values authelia -n auth > authelia-values-backup.yaml

# Step 2: Render to check
helm template authelia authelia/authelia \
  -n auth \
  -f authelia-values.yaml > authelia-rendered.yaml

# Step 3: Lint
helm lint authelia/authelia -n auth -f authelia-values.yaml

# Step 4: Upgrade
helm upgrade authelia authelia/authelia \
  -n auth \
  -f authelia-values.yaml

# Step 5: Verify
kubectl rollout status deployment/authelia -n auth
```

---

## 📖 What's Next?

### Immediate (Stage 2A)
- [ ] Add additional users/groups
- [ ] Test password changes
- [ ] Verify session expiry behavior
- [ ] Test logout functionality

### Short-term (Stage 2B)
- [ ] Enable TOTP/2FA
- [ ] Add MFA to authentication flow
- [ ] Test 2FA login

### Integration (Stage 2C)
- [ ] Protect Grafana with Authelia
- [ ] Protect Prometheus
- [ ] Protect admin applications

### Advanced (Stage 2D)
- [ ] Setup LDAP backend (if needed)
- [ ] Integrate with existing directory
- [ ] Enable OIDC for kubectl

---

**Last Updated:** 2024  
**Status:** Production-Ready (Homelab)  
**See Also:** [RBAC & User Authentication (Stage 2B)](./Stage_2B_RBAC_User_Authentication.md)
