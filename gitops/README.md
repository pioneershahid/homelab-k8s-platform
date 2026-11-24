# Homelab Applications Migration Guide
# From Docker Compose to ArgoCD & Kubernetes

This guide outlines the transition of your standalone Docker Compose stacks in `scripts-kubeadm/Applications` into production Kubernetes workloads managed via **GitOps (ArgoCD)**.

---

## 1. Directory Structure

```text
gitops/
├── bootstrap/
│   ├── install-argocd.sh             # Deploys ArgoCD & applies root app
│   └── root-application.yaml         # ArgoCD Root Application (App-of-Apps)
├── platform/
│   ├── storage/
│   │   ├── persistent-volumes.yaml   # Maps /mnt/shared and /mnt/cctv
│   │   └── storageclass-smb.yaml     # SMB CSI StorageClass
│   └── traefik/
│       ├── dev-prod-routes.yaml      # Routes for dev.k8s.local & prod.k8s.local
│       ├── external-services.yaml    # Reverse proxy to Proxmox, Pi-hole, Gitea
│       ├── middlewares.yaml          # Security headers & Authelia SSO
│       └── argocd-ingressroute.yaml  # Traefik route for argocd.k8s.local
├── apps-manifests/                   # ArgoCD Application manifests
│   ├── app-cert-manager.yaml         # Jetstack cert-manager (Wave -2)
│   ├── app-smb-csi.yaml              # Kubernetes SMB CSI driver (Wave -1)
│   ├── app-traefik.yaml              # Traefik v3 Ingress Controller (Wave 0)
│   ├── app-monitoring.yaml           # Prometheus & Grafana (Wave 0)
│   ├── app-homepage.yaml             # Homepage dashboard (Wave 0)
│   ├── app-ckad-lab.yaml             # Multi-tier dev & prod lab (Wave 1)
│   ├── app-frigate.yaml              # Frigate NVR (Wave 1)
│   ├── app-immich.yaml               # Immich Photos (Wave 1)
│   └── app-wazuh.yaml                # Wazuh SIEM (Wave 1)
└── apps/
    ├── portfolio/                    # Shahid Portfolio Web App
    └── ckad-lab/                     # Dev and Prod multi-tier manifests
```

---

## 2. Bootstrapping Steps

1. **Ensure Cluster is Ready**:
   Run `./02_distribute_and_run.sh` to provision the 3-master HA cluster.
2. **Install ArgoCD**:
   ```bash
   ./gitops/bootstrap/install-argocd.sh
   ```
3. **Connect Git Repository**:
   In `gitops/bootstrap/root-application.yaml`, update `repoURL` with your git repository link.
4. **Syncing Applications**:
   ArgoCD will automatically reconcile and deploy:
   - **Traefik** (with NodePorts 30080/30443 matching your HAProxy LB configuration)
   - **kube-prometheus-stack** (Prometheus & Grafana dashboards)
   - **Immich**, **Frigate**, and **Homepage**

---

## 3. Storage Mapping

- `/mnt/shared` is mapped to `local-shared` storage class.
- `/mnt/cctv` is mounted directly for Frigate recordings with shared memory IPC (`/dev/shm`).
