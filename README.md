# Proxmox High-Availability Kubernetes Automation (`k8s-kubeadmV2`)

This repository provides a fully automated pipeline for deploying a production-grade High-Availability (HA) Kubernetes cluster on Proxmox VE using **Kubeadm**, **Calico CNI**, **Traefik Ingress**, and **ArgoCD GitOps**.

The cluster features a **3-node control plane** to guarantee etcd quorum stability, a dual-homed HAProxy load balancer bridging private and home networks, and an automated GitOps engine managing storage and platform workloads.

---

## 🚀 Quick Start Guide

### 1. Prerequisites
- **Proxmox VE**: Access to a Proxmox host (IP: `192.168.1.35`).
- **Ubuntu Template**: A cloud-init ready Ubuntu template (ID: `800`) on the Proxmox host.
- **SSH Keys**: Ensure your public key is copied to Proxmox (`ssh-copy-id root@192.168.1.35`).

### 2. Cluster Deployment Workflow
Run everything cleanly using the unified [manage_k8s.sh](manage_k8s.sh) controller:

```bash
# 1. Cleanly provision VMs on Proxmox and bootstrap HA Kubeadm:
./manage_k8s.sh setup

# 2. Deploy GitOps engine (ArgoCD), Traefik Ingress, and all workloads:
./manage_k8s.sh apps

# 3. Power management & teardown:
./manage_k8s.sh start
./manage_k8s.sh stop
./manage_k8s.sh delete
```

---

## 📐 Cluster Topology

| Hostname | Role | IP Address (Internal) | External Access | Hardware Specs |
|:---|:---|:---|:---|:---|
| `kubeadm-ha-lb` | HAProxy Load Balancer | `192.168.56.30` | `192.168.1.150` | 2 vCPU, 2GB RAM, 10GB Disk |
| `kubeadm-ha-master-1` | Control Plane 1 (Bootstrap) | `192.168.56.11` | - | 2 vCPU (`host`), 3GB RAM, 10GB Disk |
| `kubeadm-ha-master-2` | Control Plane 2 (Quorum) | `192.168.56.12` | - | 2 vCPU (`host`), 3GB RAM, 10GB Disk |
| `kubeadm-ha-master-3` | Control Plane 3 (Quorum) | `192.168.56.13` | - | 2 vCPU (`host`), 3GB RAM, 10GB Disk |
| `kubeadm-ha-worker-1` | Worker Node 1 | `192.168.56.21` | - | 2 vCPU (`host`), 4GB RAM, 30GB Disk |
| `kubeadm-ha-worker-2` | Worker Node 2 | `192.168.56.22` | - | 2 vCPU (`host`), 4GB RAM, 30GB Disk |

---

## 🌐 Edge Routing & Ingress (Traefik v3)

Traefik binds to NodePorts `30080` (HTTP) and `30443` (HTTPS) on all worker nodes. The dual-homed HAProxy load balancer forwards port 80 and 443 traffic directly to Traefik.

Map the following hostnames to `192.168.1.150` in your DNS / `hosts` file:
- **ArgoCD**: `http://argocd.k8s.local`
- **Portfolio App**: `http://portfolio.k8s.local` (and `http://shahidmustafa.ie`)
- **Dev Lab**: `http://dev.k8s.local`
- **Prod Lab**: `http://prod.k8s.local`
- **Homepage Dashboard**: `http://homepage.k8s.local`
- **Frigate NVR**: `http://frigate.k8s.local`
- **External LAN Proxies**: `proxmox.shahidmustafa.ie`, `pihole.shahidmustafa.ie`, `gitea.shahidmustafa.ie`

---

## 📦 GitOps Sync Waves & Workloads

Platform services are deployed in a deterministic sequence using **ArgoCD Sync Waves**:
1. **Wave -2 (`app-cert-manager.yaml`)**: Jetstack cert-manager (CRDs, CA Injector, Webhook).
2. **Wave -1 (`app-smb-csi.yaml`)**: Kubernetes SMB CSI driver (`csi-driver-smb`) & StorageClass `smb`.
3. **Wave 0 (Core Ingress & Monitoring)**: Traefik Ingress Controller, Prometheus/Grafana stack, and Homepage.
4. **Wave 1 (Workloads & Security)**: Wazuh SIEM, Frigate NVR, Immich, and Dev/Prod CKAD multi-tier lab.
5. **Wave 2 (Applications)**: Production Portfolio web application.

For deep-dive post-install instructions and diagnostics, see [POST_INSTALL_GUIDE.md](scripts-kubeadm/POST_INSTALL_GUIDE.md).

### 3. Key Automation Features

- **Centralized Binaries**: Kubernetes binaries are downloaded once on the Proxmox host and distributed to nodes via SCP, saving bandwidth and time.
- **Cgroup Driver Alignment**: Automatically configures `systemd` cgroup drivers for both `containerd` and `kubelet` to ensure stability.
- **HAProxy Load Balancer**: Automatically provisions an external Load Balancer (IP: `.30`) for the API server.
- **Edge Gateway Isolation**: Supports a dual-homed Load Balancer that bridges your home network (`vmbr0`) and the isolated K8s network (`vmbr1`), allowing secure application access via port 80/443.
 <!-- **Ingress Orchestration**: Automated deployment of Nginx Ingress Controller to manage multiple web applications through a single IP. -->
- **Ingress Orchestration**: Automated deployment of Traefik Ingress Controller with MetalLB to manage multiple web applications through a single LoadBalancer IP, while preserving fixed NodePorts for HAProxy external load balancer forwarding.
---

## 🌐 External Access & Networking

### Strategy: Edge Gateway

To access your applications from your home network (or internet), only the **Load Balancer** is exposed. The Master and Worker nodes remain isolated.

1. **Configure External IP (optional)**: Edit `scripts-kubeadm/00_config.sh` and set `EXTERNAL_LB_IP` if you are using an external gateway or reverse proxy on your home network.
2. **Deploy Ingress**: After the cluster is up, run:
   ```bash
   ./scripts-kubeadm/03_install_ingress.sh
   ```
3. **Accessing Apps**: Your apps are now reachable via the Traefik LoadBalancer IP shown by the script. Use DNS/hosts entries or your local DNS server to map hostnames like `dev.k8s.local` and `prod.k8s.local` to that IP.

### 🔑 Final DNS Configuration (Critical)
Since `dev.k8s.local` is a private domain, you must tell your machine how to find it:

#### On your Master Node (for terminal testing):
```bash
TRAEFIK_IP=$(kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "$TRAEFIK_IP dev.k8s.local prod.k8s.local" | sudo tee -a /etc/hosts
```

#### On your Windows PC (for browser access):
1. Open **Notepad** as Administrator.
2. Open `C:\Windows\System32\drivers\etc\hosts`.
3. Add the following line at the bottom, replacing `<TRAEFIK_IP>` with the IP shown by `kubectl get svc -n traefik traefik`:
   ```text
   <TRAEFIK_IP> dev.k8s.local prod.k8s.local
   ```
4. Save and restart your browser.

#### 💡 Pro Tip: Local DNS (Pi-hole / AdGuard)
If you have a local DNS server like **Pi-hole**:
1. Go to **Local DNS -> DNS Records**.
2. Add `dev.k8s.local` pointing to the Traefik LoadBalancer IP.
3. Add `prod.k8s.local` pointing to the Traefik LoadBalancer IP.
*This will make the cluster accessible from every device in your home automatically!*

---