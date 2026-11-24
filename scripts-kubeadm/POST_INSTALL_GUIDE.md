# Post-Kubernetes Installation & Workload Operations Guide

This guide describes how to operate, deploy, and manage workloads on your High-Availability Kubeadm cluster after running `./manage_k8s.sh setup kubeadm` or `./02_distribute_and_run.sh`.

---

## 🧭 Unified GitOps Architecture

All platform infrastructure and workloads (Traefik Ingress, cert-manager, SMB storage, Prometheus, Frigate, Immich, Wazuh, Portfolio, and the Dev/Prod CKAD lab) are now unified under **GitOps (ArgoCD)**.

There is no split between "Profile A" and "Profile B". You run a single command to deploy the entire stack:

```
                  ┌──────────────────────────────────────────────┐
                  │ HA Kubeadm Cluster (Ready)                   │
                  │ (3 Masters, 2 Workers, 1 HAProxy LB)         │
                  └──────────────────────┬───────────────────────┘
                                         │
                                         ▼
                  ┌──────────────────────────────────────────────┐
                  │ Unified GitOps Engine (ArgoCD App-of-Apps)   │
                  │ Single command: ./manage_k8s.sh apps kubeadm │
                  └──────────────────────┬───────────────────────┘
                                         │
       ┌─────────────────┬───────────────┴───────────────┬─────────────────┐
       ▼                 ▼                               ▼                 ▼
┌──────────────┐  ┌──────────────┐               ┌──────────────┐   ┌──────────────┐
│ Platform     │  │ Ingress      │               │ Applications │   │ Dev/Prod Lab │
│ cert-manager │  │ Traefik v3   │               │ Portfolio    │   │ Namespaces   │
│ SMB CSI      │  │ NodePorts    │               │ Homepage     │   │ Dev / Prod   │
│ StorageClass │  │ 30080/30443  │               │ Frigate, etc.│   │ Redis + Nginx│
└──────────────┘  └──────────────┘               └──────────────┘   └──────────────┘
```

> [!IMPORTANT]
> **Traefik** is the single ingress controller for the entire cluster. It binds to NodePorts `30080` (HTTP) and `30443` (HTTPS), which are forwarded directly by the external HAProxy Load Balancer (`192.168.1.150`).

---

## 🚀 One-Command Deployment

To deploy all workloads, storage classes, Traefik edge routing, and applications:

```bash
# From repository root (Windows / CLI):
./manage_k8s.sh apps

# Or directly from the deployment workspace / master node:
./deploy_apps.sh
```

### What this automatically deploys:
1. **ArgoCD Engine**: Installed into namespace `argocd`.
2. **Storage Drivers**:
   - `cert-manager` (Wave -2)
   - `smb-csi-driver` (Wave -1) & StorageClass `smb` (`//192.168.1.29/shared`)
   - PersistentVolumes (`/mnt/shared`, `/mnt/cctv`)
3. **Traefik Edge Routing**:
   - Controller on NodePorts `30080` & `30443`
   - IngressRoutes for `argocd.k8s.local`, `dev.k8s.local`, `prod.k8s.local`, `portfolio.k8s.local`, `frigate.k8s.local`
   - Middlewares (`default-headers`, `authelia`, `addprefix-pihole`)
   - External reverse proxy services (Proxmox, Pi-hole, Gitea, Home Assistant)
4. **Dev & Prod CKAD Lab**:
   - `dev` and `prod` namespaces with ResourceQuotas, LimitRanges, Redis backends, and frontend Deployments.
5. **Homelab Applications**:
   - Wazuh SIEM, Frigate NVR, Immich, Homepage, and Shahid Portfolio Web App.

---

## 🔍 Verification & Diagnostics

To verify connectivity and check all services:
```bash
./deploy_apps.sh verify   # Runs HTTP curl checks against 192.168.1.150 for all routes
./deploy_apps.sh status   # Displays cluster-wide pod and IngressRoute status
```

---

## 🚀 Profile A: GitOps & Homelab Production (ArgoCD)

This profile is designed for automated declarative management of your persistent homelab apps.

### Step 1: Create Docker Hub Secret (If not already created)
To pull your custom container images (such as your portfolio web app) without rate limits or permission errors, ensure the secret exists in `homelab`:
```bash
read -rsp "Docker Hub PAT / Password: " DOCKER_TOKEN; echo ""
ssh ubuntu@192.168.56.11 "kubectl create namespace homelab --dry-run=client -o yaml | kubectl apply -f -"
ssh ubuntu@192.168.56.11 "kubectl create secret docker-registry dockerhub-secret \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=pioneershahid \
  --docker-password='$DOCKER_TOKEN' \
  --docker-email=pioneershahid@gmail.com \
  -n homelab --dry-run=client -o yaml | kubectl apply -f -"
unset DOCKER_TOKEN
```

### Step 2: Bootstrap ArgoCD & Storage Prerequisites
Because your cluster nodes (`192.168.56.x`) reside on an isolated internal Proxmox bridge (`vmbr1`), use `manage_k8s.sh apps` from your repository root to deploy through your Proxmox host:

```bash
# From repository root (c:\Users\shahi\Documents\k8s-kubeadmV2):
./manage_k8s.sh apps
```
*Alternatively, if you add a static route on Windows (`route add 192.168.56.0 mask 255.255.255.0 192.168.1.35`), you can run `./deploy_apps.sh` directly.*

#### 🔑 Step 2.1: Pre-Configure SMB Storage Credentials
For persistent applications (such as Wazuh Indexer/Manager) backed by SMB/CIFS (`//192.168.1.29/shared`), create the storage secret in `kube-system`:
```bash
ssh ubuntu@192.168.56.11 'read -rp "SMB username: " SMB_USER; read -rsp "SMB password: " SMB_PASS; echo ""; \
kubectl create secret generic smbcreds \
  --namespace kube-system \
  --from-literal=username="$SMB_USER" \
  --from-literal=password="$SMB_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -; \
unset SMB_USER SMB_PASS'
```

#### ⚙️ Step 2.2: Proxmox Host CPU Architecture (Wazuh AVX Requirement)
Wazuh Dashboard and Indexer require `x86-64-v2` instruction sets (AVX/SSE4.2). If your Proxmox VM processor is set to generic `kvm64`, Wazuh containers will crash on startup:
1. Open the Proxmox Web GUI (`https://192.168.1.35:8006`).
2. For each Kubernetes VM (`101` through `106`): Navigate to **Hardware** -> **Processors** -> **Edit**.
3. Set **Type** to `host` and save. (Reboot or cycle VMs to apply).

#### 📦 Platform GitOps Ordering (Sync Waves)
The Root Application (`root-application.yaml`) manages deployment order using ArgoCD Sync Waves:
1. **Wave -2 (`app-cert-manager.yaml`)**: Jetstack cert-manager (CRDs, CA Injector, Webhook).
2. **Wave -1 (`app-smb-csi.yaml`)**: Kubernetes SMB CSI driver (`csi-driver-smb`) and `storageclass-smb.yaml`.
3. **Wave 0 (Core Ingress & Monitoring)**: Traefik Ingress (`NodePorts 30080/30443`), `kube-prometheus-stack`, Homepage.
4. **Wave 1+ (Stateful & Homelab Applications)**: Wazuh (`storageClass: smb`), Frigate NVR, Immich, Portfolio.

### Step 3: Accessing ArgoCD
1. Get the initial `admin` password:
   ```bash
   ssh ubuntu@192.168.56.11 "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
   ```
2. Access the Web GUI:
   - **Via Traefik Edge Routing (Recommended)**: Navigate to `http://argocd.k8s.local` (resolved to `192.168.1.150`).
   - **Via Port-Forward (Emergency / Diagnostic)**:
     ```bash
     ssh -L 8080:localhost:8080 ubuntu@192.168.56.11 "kubectl port-forward svc/argocd-server -n argocd 8080:443"
     ```
     Open `https://localhost:8080` in your browser (Username: `admin`).

### Step 4: Accessing Applications via Vodafone Router & Traefik
Since your Vodafone router forwards ports 80 & 443 to your Load Balancer (`192.168.1.150` / `192.168.56.30`), traffic reaches Traefik on NodePorts `30080`/`30443`:
- **Portfolio**: `http://portfolio.k8s.local` (or your external DDNS/domain)
- **Homepage Dashboard**: `http://homepage.k8s.local`
- **Frigate NVR**: `http://frigate.k8s.local`
- **Immich**: `http://photos.k8s.local`
- **Wazuh**: `http://wazuh.k8s.local`

*(Add these hostnames to your local `C:\Windows\System32\drivers\etc\hosts` or local DNS pointing to `192.168.1.150`).*

---

## 🎯 Profile B: Multi-tier Dev/Prod Lab (Traefik Ingress)

This profile deploys multi-tier applications (`dev` and `prod` frontend/backend) exposed through **Traefik**.

### Step 1: Deploy Traefik & Multi-Tier Lab
```bash
./deploy_apps.sh all
```
Or run each individually:
```bash
./deploy_apps.sh ingress    # Deploys Traefik Ingress Controller (NodePorts 30080/30443)
./deploy_apps.sh ckad-lab   # Deploys dev & prod namespaces, redis, frontend, Traefik IngressRoutes & Ingress
```

### Step 2: Access Dev and Prod via Traefik
Both environments are routed through Traefik and accessible via your HAProxy Load Balancer (`192.168.1.150`):
- **Dev**: `http://dev.k8s.local/`
- **Prod**: `http://prod.k8s.local/`

### Step 3: Verify Lab Connectivity
```bash
./deploy_apps.sh verify
```
This tests HTTP responses for `dev.k8s.local` and `prod.k8s.local` through Traefik NodePorts.

---

## 🧹 Teardown & Switching Profiles

- **To clean up CKAD lab**:
  ```bash
  ssh ubuntu@192.168.56.11 "kubectl delete ns dev prod ingress-nginx"
  ```
- **To clean up ArgoCD GitOps**:
  ```bash
  ssh ubuntu@192.168.56.11 "kubectl delete -f ~/gitops/bootstrap/root-application.yaml; kubectl delete ns argocd traefik monitoring homelab"
  ```
- **To completely destroy the VMs and cluster on Proxmox**:
  ```bash
  ./manage_k8s.sh delete
  ```


Troublehooting
Kubernetes Ingress: NGINX vs. Traefik — Assessment and Implementation Notes
1. Ingress comparison: NGINX vs. Traefik
Criteria	NGINX Ingress Controller (Kubernetes)	Traefik Ingress	Assessment / recommendation
Ecosystem maturity	Industry gold standard for Kubernetes. The supplied assessment says most documentation, CKAD/CKA exams, Helm charts, and tutorials default to it.	Extremely popular in homelabs and modern microservices environments.	NGINX for stability and exam alignment; Traefik for native dynamic middleware and Let's Encrypt integration.
Configuration	Uses Kubernetes annotations, for example nginx.ingress.kubernetes.io/....	Uses custom CRDs such as IngressRoute and Middleware.	NGINX is common across enterprise Kubernetes environments.
Existing portfolio setup	When ./deploy_apps.sh all was run, NGINX Ingress was installed and mapped ports 30080/`30443` directly to it.	Traefik was installed with dynamically assigned NodePorts (32723), so HAProxy on port 80 was not forwarding to Traefik.	NGINX worked with the existing HAProxy configuration because its NodePorts matched.


2. Recommendation for this homelab: move to Traefik
The supplied assessment recommends moving to Traefik for this homelab, despite NGINX being common in Kubernetes certification material.
Why Traefik is considered a better fit for this environment
1. Existing Traefik configuration and functionality
   The supplied config.yml location is root@network:~/docker_volumes/traefik/data/. The assessment says it already contains or supports:
   - Authelia forward authentication (authelia middleware).
   - Security headers (HSTS, nosniff, frameDeny).
   - Routing to non-Kubernetes LAN hosts:
     - Proxmox: port 8006
     - Pi-hole: port 80
     - Gitea: port 3000
     - Home Assistant: port 8123
   Recreating these in NGINX Ingress was assessed as less convenient:
   - Authelia forward authentication in NGINX uses annotations such as nginx.ingress.kubernetes.io/auth-url and may involve snippet annotations.
   - Routing external non-Kubernetes IPs through NGINX Ingress may require manually created headless Services and EndpointSlices.
2. The earlier Traefik issue was attributed to a NodePort mismatch
   The supplied explanation says:
   - ./deploy_apps.sh all installed NGINX Ingress first, and NGINX claimed NodePort 30080.
   - Traefik was installed afterwards and received a different NodePort, 32723.
   - HAProxy continued sending traffic to 30080, so it reached NGINX rather than Traefik.
   - The proposed correction was to remove NGINX and assign NodePorts 30080 and 30443 to Traefik.
3. Traefik CRDs are declarative and GitOps-friendly
   Traefik uses resources such as IngressRoute and Middleware, which the supplied assessment considers a close match for the existing Docker Compose routing logic.
3. Proposed migration architecture
The supplied target architecture is:
Internet / Home Network (Vodafone Router)
                  |
                  v
       HAProxy Load Balancer (.150 / .30)
             Port 80 / 443 forwarding
                  |
                  v
          NodePorts 30080 / 30443
                  |
                  v
            Traefik Ingress (K8s)
                  |
          +-------+-------+
          |               |
          v               v
  Authelia Middleware   Default Security Headers
          |
    +-----+-------------------------------+
    |                                     |
    v                                     v
Kubernetes applications             External LAN apps
    |                                     |
    +-- shahidmustafa.ie                 +-- proxmox.shahidmustafa.ie (192.168.1.35)
    +-- immich.shahidmustafa.ie          +-- pihole.shahidmustafa.ie (192.168.1.19)
    +-- frigate.shahidmustafa.ie         +-- gitea.shahidmustafa.ie (192.168.1.26)
    +-- homepage.shahidmustafa.ie        +-- hassio.shahidmustafa.ie (192.168.1.2)
4. Proposed next actions before migration
1. Uninstall ingress-nginx to free NodePorts 30080 and 30443.
2. Configure Traefik in app-traefik.yaml to use NodePorts 30080 and 30443.
3. Populate middlewares.yaml and external-services.yaml with the existing Docker Compose rules.
5. Frigate CrashLoopBackOff: supplied diagnosis
Kubernetes events supplied
The Frigate pod events included:
Type     Reason     Age                  From               Message
----     ------     ----                 ----               -------
Normal   Scheduled  12m                  default-scheduler  Successfully assigned homelab/frigate-574f6757fd-kjvwt to kubeadm-ha-worker-1
Normal   Pulling    12m                  kubelet            spec.containers{frigate}: Pulling image "ghcr.io/blakeblackshear/frigate:stable"
Normal   Pulled     5m14s                kubelet            spec.containers{frigate}: Successfully pulled image "ghcr.io/blakeblackshear/frigate:stable" in 7m3.574s (7m3.574s including waiting). Image size: 2161192761 bytes.
Normal   Created    76s (x6 over 5m14s)  kubelet            spec.containers{frigate}: Container created
Normal   Started    76s (x6 over 5m14s)  kubelet            spec.containers{frigate}: Container started
Normal   Pulled     76s (x5 over 4m55s)  kubelet            spec.containers{frigate}: Container image "ghcr.io/blakeblackshear/frigate:stable" already present on machine and can be accessed by the pod
Warning  BackOff    64s (x6 over 4m41s)  kubelet            spec.containers{frigate}: Back-off restarting failed container frigate in pod frigate-574f6757fd-kjvwt_homelab(f6047cc5-0078-41d5-9150-17ab582fc4e3)
Supplied diagnosis
The reported problem was that Frigate requires a writable /config directory because it generates go2rtc_homekit.yml and creates /config/model_cache during startup.

The supplied diagnosis says that mounting a standard Kubernetes ConfigMap directly over /config made the directory read-only, producing an error like:
OSError: [Errno 30] Read-only file system: '/config/model_cache'
Supplied fix
The reported change in gitops/apps-manifests/app-frigate.yaml was:
- Mount a writable emptyDir at /config.
- Mount the frigate-config ConfigMap using subPath: config.yml into /config/config.yml.
The supplied result was that Frigate reached 1/1 Running:
NAME                       READY   STATUS    RESTARTS   AGE
frigate-759c4bfc7b-qfrr8   1/1     Running   0          5s
6. Traefik implementation reported as complete
The supplied implementation summary reports the following work.
6.1 NodePorts
- Removed the conflicting ingress-nginx service.
- Assigned Traefik NodePort 30080 for HTTP.
- Assigned Traefik NodePort 30443 for HTTPS.
- Intended to align these ports with HAProxy on 192.168.1.150.
6.2 Middlewares
File: gitops/platform/traefik/middlewares.yaml

The reported middlewares are:
- default-headers: HSTS, SAMEORIGIN, nosniff, and X-Forwarded-Proto: https.
- authelia: forward authentication to http://authelia:9091/api/authz/forward-auth?rd=https://auth.shahidmustafa.ie.
- addprefix-pihole: injects /admin.
- default-whitelist: allows 10.0.0.0/8, 192.168.1.0/24, and 172.16.0.0/12.
- https-redirectscheme: redirects HTTP to HTTPS.
6.3 External LAN routing
File: gitops/platform/traefik/external-services.yaml

The reported routes are:
Hostname	Backend	Reported middleware
proxmox.shahidmustafa.ie	192.168.1.35:8006	Authelia
pihole.shahidmustafa.ie	192.168.1.19:80	Authelia and /admin prefix
gitea.shahidmustafa.ie	192.168.1.26:3000	Authelia
hassio.shahidmustafa.ie	192.168.1.2:8123	Not specified in the supplied summary


7. Live verification results supplied
The supplied tests were sent through the load balancer at 192.168.1.150:80, which was described as forwarding to Traefik NodePort 30080.
Portfolio
Command:
curl.exe -sI -H "Host: shahidmustafa.ie" http://192.168.1.150/
Reported response:
HTTP/1.1 200 OK
Server: Apache/2.4.71 (Debian)
Strict-Transport-Security: max-age=15552000; includeSubDomains; preload
Frigate NVR
Command:
curl.exe -sI -H "Host: frigate.k8s.local" http://192.168.1.150/
Reported response:
HTTP/1.1 200 OK
Server: nginx/1.30.7
Strict-Transport-Security: max-age=15552000; includeSubDomains; preload
The supplied assessment says both the portfolio web app and Frigate returned 200 OK through the load balancer.
8. Outstanding request: deploy and verify all applications
The following operational work was requested but is not confirmed as completed in the supplied information:
Push updated code to Kubernetes and assess whether the development backend and frontend are using Traefik as well. Run all apps in apps-manifest and check if they are running fine.

Suggested verification scope
1. Review the current repository and identify all application manifests in the apps-manifest directory.
2. Check the frontend and backend Kubernetes Services, Ingress or IngressRoute resources, hostnames, ports, and middleware references.
3. Confirm that the frontend and backend routes are handled by Traefik, rather than the old NGINX controller.
4. Check that HAProxy forwards to Traefik on NodePorts 30080 and 30443.
5. Apply or reconcile the updated manifests using the repository's normal deployment workflow.
6. Check all application workloads for readiness, restarts, scheduling problems, image-pull errors, and failing probes.
7. Test each application through its intended hostname and verify the corresponding Traefik routing.
Suggested Kubernetes checks
kubectl get nodes
kubectl get pods -A -o wide
kubectl get deployments -A
kubectl get statefulsets -A
kubectl get daemonsets -A
kubectl get services -A
kubectl get ingress -A
kubectl get ingressroutes -A
kubectl get endpointslices -A
For an application that is not healthy:
kubectl -n <namespace> describe pod <pod-name>
kubectl -n <namespace> logs <pod-name> --all-containers
kubectl -n <namespace> logs <pod-name> --previous
kubectl -n <namespace> get events --sort-by=.lastTimestamp
For a deployment rollout:
kubectl -n <namespace> rollout status deployment/<deployment-name>
Example host-header test through HAProxy:
curl -sSI -H "Host: <application-hostname>" http://192.168.1.150/
Example HTTPS test:
curl -sSI https://<application-hostname>/
A running pod alone does not prove that the application is routed through Traefik. Confirm the Ingress/IngressRoute configuration, Service endpoints, Traefik logs, and a request through the expected hostname.