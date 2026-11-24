# Kubernetes Homelab — Stage 2: Identity & Authentication

## Status

**Stage 2 core authentication is working end-to-end.**

Working stack:

- Kubernetes kubeadm cluster
- 3 masters: `192.168.56.11`, `.12`, `.13`
- 2 workers: `192.168.56.21`, `.22`
- Load balancer: `192.168.56.30`
- LAN-facing address: `192.168.1.150`
- Traefik `3.7.1`
- Authelia `4.39.20`
- Authelia Helm chart `0.11.6`
- Redis for Authelia sessions
- File-based Authelia users
- cert-manager wildcard TLS
- Traefik ForwardAuth
- NGINX sample application at `dev.k8s.local`

LDAP/OpenLDAP was previously attempted but did not produce a reliable working setup. The current stable implementation therefore uses **Authelia file authentication + Redis**. LDAP can be revisited later.

---

# 1. Architecture

```text
                         LAN / Internet
                              |
                         192.168.1.150
                              |
                       Load Balancer
                              |
                       192.168.56.30
                              |
                           Traefik
                              |
             +----------------+----------------+
             |                                 |
      auth.k8s.local                    dev.k8s.local
             |                                 |
             v                                 v
         Authelia                         ForwardAuth
                                               |
                                               v
                                            Authelia
                                               |
                                      authenticated?
                                         /       \
                                       no         yes
                                       |           |
                                      302         allow
                                       |           |
                                       |           v
                                       |        frontend
                                       |           |
                                       |           v
                                       |         NGINX
                                       |
                                       v
                              auth.k8s.local login
```

The important distinction is:

- `auth.k8s.local` = authentication portal
- `dev.k8s.local` = protected sample application

**Do not protect `auth.k8s.local` with its own Authelia ForwardAuth middleware.** That would create an authentication loop.

---

# 2. Kubernetes Nodes

| Role | IP |
|---|---|
| Master 1 | `192.168.56.11` |
| Master 2 | `192.168.56.12` |
| Master 3 | `192.168.56.13` |
| Worker 1 | `192.168.56.21` |
| Worker 2 | `192.168.56.22` |
| Load Balancer | `192.168.56.30` |
| LAN/Internet-facing path | `192.168.1.150` |

Check:

```bash
kubectl get nodes -o wide
```

---

# 3. Namespaces

Authentication components:

```text
auth
```

Application:

```text
dev
```

Traefik:

```text
traefik
```

Check:

```bash
kubectl get ns
kubectl create namespace auth
```

---

# 4. Redis

Redis is the Authelia session backend.

```
kubectl apply -f redis.yaml

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
          #valueFrom:
          #  secretKeyRef:
          #    name: authelia-secrets
          #    key: REDIS_PASSWORD
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
```

Check:

```bash
kubectl get pods -n auth
```

Expected:

```text
authelia-xxxxx   1/1   Running
redis-xxxxx      1/1   Running
```

## Test Redis

```bash
export REDIS_PASSWORD=$(kubectl get secret authelia-redis-secret   -n auth   -o jsonpath='{.data.session\.redis\.password\.txt}' | base64 -d)
```

Then:

```bash
kubectl exec -n auth deploy/redis --   sh -c 'redis-cli -a "$REDIS_PASSWORD" ping'
```

Expected:

```text
PONG
```

### Redis failure symptom

If Authelia logs:

```text
WRONGPASS invalid username-password pair
```

Authelia will normally enter `CrashLoopBackOff`.

Fix Redis configuration first, verify `PONG`, then restart Authelia:

```bash
kubectl rollout restart deployment/authelia -n auth
```

---

# 5. Authelia

Current working version:

```text
4.39.20
```

Check:

```bash
kubectl exec -n auth deploy/authelia -- authelia version
```

Expected:

```text
Version: 4.39.20
```

Helm release:

```bash
helm list -n auth
```

Working chart:

```text
authelia/authelia
0.11.6
```

---

# 6. Authelia Users

Authentication uses:

```text
config/users_database.yml
```

The Kubernetes ConfigMap is:

```text
authelia-users
```

Check:

```bash
kubectl get configmap -n auth authelia-users
```

The file is mounted in the Authelia container as:

```text
/config/users_database.yml
```

Authelia logs should show:

```text
Watching file for changes file=/config/users_database.yml
```

Typical structure:

```yaml
docker run --rm authelia/authelia:4.39.20 authelia crypto hash generate argon2 --password 'MySecretPassword'

nano users_database.yml

users:
  admin:
    disabled: false
    displayname: "Kubernetes Administrator"
    password: "PASTE_ARGON2_HASH_HERE"
    email: "admin@k8s.local"
    groups:
      - admins
      - dev
```

The username is the key under `users:`.

The password stored in the file is an Argon2 hash. The original plaintext password cannot be recovered from the hash.

If a password is forgotten, generate a new hash and update the user database.

---

# 7. Updating users_database.yml

Edit:

```bash
nano config/users_database.yml
```

Update the ConfigMap:

```bash
kubectl create configmap authelia-users   -n auth   --from-file=users_database.yml=config/users_database.yml   --dry-run=client -o yaml | kubectl apply -f -
```

Verify:

```bash
kubectl get configmap authelia-users -n auth
```

If required:

```bash
kubectl rollout restart deployment/authelia -n auth
```

---

# 8. Authelia Secrets

Important Secrets:

```text
authelia
authelia-session-secret
authelia-redis-secret
authelia-storage-secret
```

Check:

```bash
kubectl get secrets -n auth
```

Do not commit actual secret values to Git.

The Helm chart required `authelia-session-secret` to be configured as an additional secret because it is used for the session encryption key.

````
Step 2 — Create session encryption secret

Generate a new value:
openssl rand -hex 32


Create:
kubectl create secret generic authelia-session-secret \
  -n auth \
  --from-literal=session.encryption.key='YOUR-NEW-SESSION-SECRET'

Verify:

kubectl get secret -n auth authelia-session-secret
Step 3 — Create storage encryption secret

Generate another:
openssl rand -hex 32

Create:
kubectl create secret generic authelia-storage-secret \
  -n auth \
  --from-literal=storage.encryption.key='YOUR-NEW-STORAGE-SECRET'

Verify:
kubectl get secret -n auth authelia-storage-secret

authelia-users
authelia-secrets
authelia-redis-secret
authelia-session-secret
authelia-storage-secret

````

---

# 9. Authelia config

The critical working configuration is:

```yaml
ubuntu@kubeadm-ha-master-1:~$ cat authelia-values.yaml 
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
    authelia-redis-secret: {} #cd7458ff319b19cb18166f49cc6334ab76773a6201614508a9550f888d3ffd1c
    authelia-storage-secret: {} #1c93373b810487f1f58489dd76fa1fde6a274130b574ce196ff2c657da82bb68

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
```

````
helm template authelia authelia/authelia \
  --namespace auth \
  --version 0.11.6 \
  -f authelia-values.yaml > authelia-rendered.yaml

helm lint authelia/authelia \
  --version 0.11.6 \
  -f authelia-values.yaml

helm upgrade --install authelia authelia/authelia \
  --namespace auth \
  --version 0.11.6 \
  -f authelia-values.yaml

kubectl get pods -n auth -w  
kubectl get svc -n auth
kubectl get endpoints -n auth
````

---

# 10. Authelia Portal

Portal:

```text
https://auth.k8s.local
```

Test:

```bash
curl -k -I https://auth.k8s.local
```

Expected:

```text
HTTP/2 200
content-type: text/html
```

The portal itself must not use the Authelia ForwardAuth middleware.

---

# 11. TLS

cert-manager provides a wildcard certificate.

Certificate:

```text
wildcard-k8s-local
```

Secret:

```text
wildcard-k8s-local-tls
```

Namespace:

```text
dev
```

Certificate covers:

```text
*.k8s.local
```

Therefore it can cover:

```text
dev.k8s.local
auth.k8s.local
```

Check:

```bash
kubectl get certificate -n dev
```

Expected:

```text
wildcard-k8s-local   True   wildcard-k8s-local-tls
```

Detailed check:

```bash
kubectl describe certificate -n dev wildcard-k8s-local
```

---

# 12. Traefik

Traefik version:

```text
3.7.1
```

Check:

```bash
kubectl exec -n traefik deploy/traefik -- traefik version
```

Important providers:

```text
--providers.kubernetescrd
--providers.kubernetesingress
```

Important CRD settings:

```text
--providers.kubernetescrd.allowCrossNamespace=true
--providers.kubernetescrd.namespaces=dev,traefik
```

Check:

```bash
kubectl get deployment traefik -n traefik   -o jsonpath='{.spec.template.spec.containers[0].args}'
```

---

# 13. Authelia ForwardAuth Middleware

Middleware:

```text
dev/authelia
```

Check:

```bash
kubectl get middleware -n dev authelia -o yaml
```

Working configuration:

```yaml
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
```

The important endpoint is:

```text
http://authelia.auth.svc.cluster.local/api/authz/forward-auth
```

This uses Kubernetes service DNS.

---

# 14. HTTPS Redirect Middleware

Middleware:

```text
dev/redirect-https
```

Check:

```bash
kubectl get middleware -n dev redirect-https -o yaml
```

Working configuration:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
  namespace: dev
spec:
  redirectScheme:
    scheme: https
    permanent: true
```

---

# 15. Protected NGINX Application

The sample application is:

```text
https://dev.k8s.local
```

Ingress:

```text
frontend-ingress
```

Namespace:

```text
dev
```

Check:

```bash
kubectl describe ingress -n dev frontend-ingress
```

Expected:

```text
Host:
    dev.k8s.local

Backend:
    frontend:80

TLS:
    wildcard-k8s-local-tls
```

The middleware annotation is:

```yaml
traefik.ingress.kubernetes.io/router.middlewares: dev-redirect-https@kubernetescrd,dev-authelia@kubernetescrd
```

Order:

```text
HTTP
 ↓
HTTPS redirect
 ↓
Authelia ForwardAuth
 ↓
frontend
```

---

# 16. Why Middleware References Have `dev-`

Because the middleware is in the `dev` namespace:

```text
dev/authelia
dev/redirect-https
```

Traefik references them as:

```text
dev-authelia@kubernetescrd
dev-redirect-https@kubernetescrd
```

Format:

```text
<namespace>-<middleware>@kubernetescrd
```

If Traefik reports:

```text
middleware "dev-authelia@kubernetescrd" does not exist
```

check:

```bash
kubectl get middleware -A
```

and:

```bash
kubectl get middleware -n dev authelia -o yaml
```

---

# 17. Important Previous Middleware Issue

Earlier Traefik reported:

```text
middleware "dev-redirect-https@kubernetescrd" does not exist
```

even though:

```bash
kubectl get middleware -n dev
```

showed:

```text
redirect-https
```

The Middleware was recreated and Traefik was allowed to discover it correctly.

If this problem returns:

```bash
kubectl get middleware -A
```

```bash
kubectl logs -n traefik deploy/traefik --since=5m | grep -i middleware
```

Then verify the Ingress annotation.

---

# 18. Correct ForwardAuth Test

Do not test the ForwardAuth endpoint like a normal application endpoint.

A plain request:

```bash
curl http://authelia.auth.svc.cluster.local/api/authz/forward-auth
```

returned:

```text
400 Bad Request
```

This was expected because Traefik normally supplies forwarded request metadata.

The correct test is:

```bash
kubectl run auth-test   -n dev   --rm -it   --restart=Never   --image=curlimages/curl:8.12.1   --   curl -i     -H 'X-Forwarded-Method: GET'     -H 'X-Forwarded-Proto: https'     -H 'X-Forwarded-Host: dev.k8s.local'     -H 'X-Forwarded-URI: /'     http://authelia.auth.svc.cluster.local/api/authz/forward-auth
```

Known-good result:

```text
HTTP/1.1 302 Found
```

and:

```text
Location: https://auth.k8s.local/?rd=https%3A%2F%2Fdev.k8s.local%2F&rm=GET
```

This proves Authelia is correctly processing the protected application request.

---

# 19. Browser Authentication Workflow

Use an InPrivate/Incognito browser window.

Open:

```text
https://dev.k8s.local
```

Expected:

```text
dev.k8s.local
    ↓
Traefik
    ↓
ForwardAuth
    ↓
Authelia
    ↓
anonymous
    ↓
302
    ↓
https://auth.k8s.local
```

The Authelia login page appears at:

```text
https://auth.k8s.local
```

Log in using the username/password defined by `users_database.yml`.

After successful authentication:

```text
auth.k8s.local
    ↓
session created
    ↓
redirect to dev.k8s.local
    ↓
Traefik ForwardAuth
    ↓
Authelia validates session
    ↓
frontend
    ↓
NGINX
```

---

# 20. Session Cookie

A successful ForwardAuth response issued:

```text
Set-Cookie: authelia_session=...
```

with properties including:

```text
domain=k8s.local
path=/
HttpOnly
secure
SameSite=Lax
```

This allows the authentication session to work across:

```text
auth.k8s.local
dev.k8s.local
```

The session is backed by Redis.

---

# 21. Verify Login

After logging in:

1. Open `https://dev.k8s.local`
2. Confirm the NGINX Welcome page appears.
3. Open another tab to `https://dev.k8s.local`.
4. Confirm it does not ask for login again while the session is valid.
5. Open `https://auth.k8s.local`.
6. Confirm the existing session is recognized.

---

# 22. Verify Logout

After login:

1. Go to `https://auth.k8s.local`.
2. Log out.
3. Return to `https://dev.k8s.local`.

Expected:

```text
dev.k8s.local
    ↓
Authelia
    ↓
anonymous
    ↓
302
    ↓
auth.k8s.local
```

This proves the session is actually enforced.

---

# 23. DNS

The Kubernetes master can use:

```text
192.168.56.30
```

for local testing.

Check:

```bash
getent hosts dev.k8s.local
getent hosts auth.k8s.local
```

Expected in the current master testing setup:

```text
192.168.56.30 dev.k8s.local
192.168.56.30 auth.k8s.local
```

For normal LAN clients, configure the appropriate DNS/Pi-hole records for the LAN-facing load-balancer path.

Important:

`/etc/hosts` on a Kubernetes master affects only that machine. It does not change DNS for Windows/browser clients.

---

# 24. Useful Diagnostic Commands

## All nodes

```bash
kubectl get nodes -o wide
```

## All authentication resources

```bash
kubectl get all -n auth
kubectl get secrets -n auth
kubectl get configmaps -n auth
```

## Authelia logs

```bash
kubectl logs -n auth deploy/authelia --tail=50
```

Live:

```bash
kubectl logs -n auth deploy/authelia -f
```

## Redis

```bash
kubectl get pods -n auth
```

```bash
kubectl exec -n auth deploy/redis -- redis-cli ping
```

Authenticated:

```bash
export REDIS_PASSWORD=$(kubectl get secret authelia-redis-secret   -n auth   -o jsonpath='{.data.session\.redis\.password\.txt}' | base64 -d)

kubectl exec -n auth deploy/redis --   sh -c 'redis-cli -a "$REDIS_PASSWORD" ping'
```

## Traefik

```bash
kubectl get pods -n traefik -o wide
```

```bash
kubectl logs -n traefik deploy/traefik --tail=50
```

Search:

```bash
kubectl logs -n traefik deploy/traefik --since=5m | grep -Ei "error|middleware|authelia"
```

## Middleware

```bash
kubectl get middleware -A
```

```bash
kubectl get middleware -n dev authelia -o yaml
```

```bash
kubectl get middleware -n dev redirect-https -o yaml
```

## Ingress

```bash
kubectl get ingress -n dev
```

```bash
kubectl describe ingress -n dev frontend-ingress
```

## TLS

```bash
kubectl get certificate -n dev
```

```bash
kubectl describe certificate -n dev wildcard-k8s-local
```

---

# 25. Backups Before Changes

Ingress:

```bash
kubectl get ingress frontend-ingress -n dev -o yaml   > frontend-ingress-backup.yaml
```

Authelia values:

```bash
cp authelia-values.yaml authelia-values.yaml.backup
```

Redis:

```bash
cp redis.yaml redis.yaml.backup
```

Middleware:

```bash
kubectl get middleware -n dev authelia -o yaml   > authelia-middleware-backup.yaml
```

---

# 26. Helm Upgrade Procedure

Always render first:

```bash
helm template authelia authelia/authelia   --namespace auth   --version 0.11.6   -f authelia-values.yaml   > authelia-rendered.yaml
```

Lint:

```bash
helm lint authelia/authelia   --version 0.11.6   -f authelia-values.yaml
```

Upgrade:

```bash
helm upgrade authelia authelia/authelia   --namespace auth   --version 0.11.6   -f authelia-values.yaml
```

Then:

```bash
kubectl rollout status deployment/authelia -n auth
```

---

# 27. Quick Recovery Procedure

When returning to this project later, use this exact sequence.

## Step 1 — Cluster

```bash
kubectl get nodes -o wide
```

## Step 2 — Pods

```bash
kubectl get pods -n traefik
kubectl get pods -n auth
kubectl get pods -n dev
```

## Step 3 — Ingress and Middleware

```bash
kubectl get middleware -n dev
kubectl get ingress -n dev
kubectl get certificate -n dev
```

## Step 4 — Authelia

```bash
curl -k -I https://auth.k8s.local
```

Expected:

```text
HTTP/2 200
```

## Step 5 — Protected application

```bash
curl -k -I https://dev.k8s.local
```

When unauthenticated, expected:

```text
HTTP/2 302
location: https://auth.k8s.local/?rd=...
```

## Step 6 — Authelia logs

```bash
kubectl logs -n auth deploy/authelia --tail=30
```

## Step 7 — Traefik logs

```bash
kubectl logs -n traefik deploy/traefik --since=5m | grep -Ei "error|middleware|authelia"
```

## Step 8 — Browser

Open:

```text
https://dev.k8s.local
```

Authenticate through:

```text
https://auth.k8s.local
```

Verify NGINX loads.

---

# 28. Stage 2 Completion Checklist

## Infrastructure

- [x] `auth` namespace
- [x] Redis deployed
- [x] Redis password configured
- [x] Redis authentication verified
- [x] Authelia deployed with Helm
- [x] Authelia starts successfully
- [x] File-based authentication configured
- [x] `users_database.yml` mounted
- [x] Session storage configured with Redis

## TLS / Ingress

- [x] Wildcard TLS certificate
- [x] `auth.k8s.local`
- [x] `dev.k8s.local`
- [x] HTTPS
- [x] HTTP → HTTPS redirect
- [x] Traefik ForwardAuth
- [x] Authelia Middleware
- [x] Application Ingress

## Authentication

- [x] `auth.k8s.local` bypass
- [x] `dev.k8s.local` one-factor policy
- [x] Default deny
- [x] Unauthenticated request → 302
- [x] Redirect to Authelia
- [x] Login
- [x] Session cookie
- [x] Redis session
- [x] Authenticated request → NGINX
- [x] Logout → authentication required again

**Stage 2 core objective: COMPLETE.**

---

# 29. Recommended Next Steps

Do not change the current working authentication stack until it has been backed up.

Recommended order:

## Stage 2A — Authentication hardening

1. Test multiple users.
2. Test groups.
3. Test invalid passwords.
4. Test logout.
5. Test session expiry.
6. Test Redis restart/session behavior.
7. Configure password reset if required.

## Stage 2B — MFA

Add TOTP/2FA.

Target flow:

```text
username
   +
password
   +
TOTP
```

## Stage 2C — Protect Grafana

Target:

```text
grafana.k8s.local
        |
      Traefik
        |
    Authelia
        |
      Grafana
```

## Stage 2D — Protect Flask

Target:

```text
flask.k8s.local
       |
     Traefik
       |
   Authelia
       |
     Flask
```

## Stage 2E — Groups / Authorization

Example:

```text
admins
developers
users
```

Then policies can be created such as:

```text
grafana.k8s.local
    admins + developers

admin.k8s.local
    admins only

app.k8s.local
    users + developers + admins
```

---

# 30. Final Known-Good Architecture

```text
                         USER
                           |
                           v
                    dev.k8s.local
                           |
                           v
                     Load Balancer
                           |
                           v
                        Traefik
                           |
                           v
                     ForwardAuth
                           |
                           v
                        Authelia
                      /         \
                anonymous       session
                   |               |
                  302             allow
                   |               |
                   v               v
             auth.k8s.local     frontend
                   |               |
                Login              v
                               NGINX
```

Current stable authentication architecture:

```text
Traefik
   ↓
Authelia
   ↓
File-based users
   +
Redis sessions
   ↓
Applications
```

LDAP is intentionally not in the current working path.

This is the baseline to preserve before moving to MFA, Grafana, Flask, groups, or a future LDAP/identity-provider integration.
