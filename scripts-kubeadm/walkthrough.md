# High Availability Kubeadm Setup on Proxmox

Fully automated, independent set of scripts for deploying a **Highly Available Kubeadm cluster** (3 Control Planes, 2 Workers, 1 Load Balancer).

These scripts reside in: `scripts-kubeadm/`.

## Directory Structure
```text
scripts-kubeadm/
├── 00_config.sh              # Central cluster IP/VM/credential configuration
├── 01_create_vms.sh          # Proxmox VM cloning and cloud-init setup
├── 02_distribute_and_run.sh  # Core K8s bootstrap (HAProxy, containerd, 3 CPs, 2 Workers)
├── deploy_apps.sh            # Unified GitOps & Traefik application deployment
├── utils.sh                  # Common logging and retry helpers
└── node-scripts/
    ├── install_lb.sh         # HAProxy setup (API server 6443 + Ingress ports 80/443)
    ├── install_prereqs.sh    # Containerd, sysctl, kubelet, kubeadm, kubectl
    ├── install_master1.sh    # Bootstrap first control plane & Calico CNI
    ├── join_controlplane.sh  # Join additional control plane nodes (master-2, master-3)
    ├── install_worker.sh     # Join worker nodes
    ├── verify_cluster.sh     # Core cluster health check
    └── verify_workloads.sh   # Ingress and app health check
```

## Cluster Topology (Quorum: 3 Masters)
// configured the local ~/.kube/config for the ubuntu user so kubectl commands now run seamlessly without needing root or flags. also added more details to the README.md file for the cluster config.

| Hostname | Role | IP Address | VMID |
|---|---|---|---|
| `kubeadm-ha-master-1` | Control Plane 1 (Bootstrap) | `192.168.56.11` | `311` |
| `kubeadm-ha-master-2` | Control Plane 2 (Quorum) | `192.168.56.12` | `312` |
| `kubeadm-ha-master-3` | Control Plane 3 (Quorum) | `192.168.56.13` | `313` |
| `kubeadm-ha-worker-1` | Worker Node 1 | `192.168.56.21` | `321` |
| `kubeadm-ha-worker-2` | Worker Node 2 | `192.168.56.22` | `322` |
| `kubeadm-ha-lb`       | HAProxy Load Balancer | `192.168.56.30` (Ext: `192.168.1.150`) | `330` |

---


## How It Works

### Step 1: Configuration
`00_config.sh` holds VM IDs, IPs, Proxmox template settings, and credentials.

### Step 2: Provisioning VMs
Run `./01_create_vms.sh` (or via `./manage_k8s.sh setup` from root) to clone and start all 6 VMs.

### Step 3: Automated Base Cluster Deployment
Run `./02_distribute_and_run.sh`. This script builds a clean, ready Kubernetes cluster:
1. **Load Balancer**: Configures HAProxy balancing API traffic across all 3 master nodes on port `6443`.
2. **Prerequisites**: Configures kernel modules, containerd, and installs `kubelet`, `kubeadm`, and `kubectl` on all 5 nodes.
3. **Master 1 Bootstrap**: Initializes `kubeadm init --control-plane-endpoint "192.168.56.30:6443" --upload-certs` and deploys Calico CNI.
4. **Additional Masters (Quorum)**: Joins `master-2` and `master-3` to establish an etcd quorum.
5. **Workers**: Joins `worker-1` and `worker-2`.
6. **Core Verification**: Verifies node statuses and core pods.

### Step 4: Workload Deployment
Application workloads are managed via GitOps (ArgoCD) and routed through Traefik:

```bash
# Deploy all workloads, storage classes, and Traefik ingress:
./deploy_apps.sh

# Health Check & Verification:
./deploy_apps.sh verify

# Check status of cluster pods and IngressRoutes:
./deploy_apps.sh status
```

For complete instructions on accessing ArgoCD, managing GitOps manifests, and switching profiles, see **[POST_INSTALL_GUIDE.md](POST_INSTALL_GUIDE.md)**.
