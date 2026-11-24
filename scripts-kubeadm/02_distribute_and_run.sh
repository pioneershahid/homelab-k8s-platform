#!/usr/bin/env bash
# 02_distribute_and_run.sh

set -euo pipefail
source ./00_config.sh
source ./utils.sh

log "📦 Distributing and running node scripts for Kubeadm HA..."

# 1. Setup Load Balancer
LB_NAME="kubeadm-ha-lb"
LB_IP=$(get_vm_ip "$LB_NAME")
retry_ssh "$LB_IP"
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$LB_IP" >/dev/null 2>&1 || true
log "Uploading to Load Balancer ($LB_NAME)..."
scp -o StrictHostKeyChecking=no node-scripts/install_lb.sh $K8S_USER@"$LB_IP":~/
log "Executing on Load Balancer..."
ssh -o StrictHostKeyChecking=no $K8S_USER@"$LB_IP" "echo '⏳ Waiting for system to be ready (cloud-init)...'; while ! cloud-init status | grep -q 'done'; do echo -n '.'; sleep 5; done; echo '✅ System Ready!'; while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do echo '⏳ Waiting for apt lock...'; sleep 5; done; chmod +x ~/install_lb.sh && ~/install_lb.sh"

# 2. Run Prerequisites on all nodes (except LB)
for NAME in kubeadm-ha-master-1 kubeadm-ha-master-2 kubeadm-ha-master-3 kubeadm-ha-worker-1 kubeadm-ha-worker-2; do
  IP=$(get_vm_ip "$NAME")
  retry_ssh "$IP"
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$IP" >/dev/null 2>&1 || true
  log "Uploading prerequisites script to $NAME..."
  scp -o StrictHostKeyChecking=no node-scripts/install_prereqs.sh $K8S_USER@"$IP":~/
  log "Executing prerequisites on $NAME..."
  ssh -o StrictHostKeyChecking=no $K8S_USER@"$IP" "echo '⏳ Waiting for system to be ready (cloud-init)...'; while ! cloud-init status | grep -q 'done'; do echo -n '.'; sleep 5; done; echo '✅ System Ready!'; while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do echo '⏳ Waiting for apt lock...'; sleep 5; done; chmod +x ~/install_prereqs.sh && sudo ~/install_prereqs.sh '$DOCKER_USER' '$DOCKER_TOKEN'"
done

# 3. Bootstrap First Master
MASTER1="kubeadm-ha-master-1"
MASTER1_IP=$(get_vm_ip "$MASTER1")
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$MASTER1_IP" >/dev/null 2>&1 || true
log "Uploading control plane script to $MASTER1..."
scp -o StrictHostKeyChecking=no node-scripts/install_master1.sh $K8S_USER@"$MASTER1_IP":~/
log "Executing control plane setup on $MASTER1..."
ssh -o StrictHostKeyChecking=no $K8S_USER@"$MASTER1_IP" "echo '⏳ Waiting for system to be ready (cloud-init)...'; while ! cloud-init status | grep -q 'done'; do echo -n '.'; sleep 5; done; echo '✅ System Ready!'; while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do echo '⏳ Waiting for apt lock...'; sleep 5; done; chmod +x ~/install_master1.sh && sudo ~/install_master1.sh"

# 4. Extract Join Commands and Config from Master 1
log "Extracting Kubeadm join commands and config..."
WORKER_JOIN_CMD=$(ssh -o StrictHostKeyChecking=no $K8S_USER@"$MASTER1_IP" "sudo kubeadm token create --print-join-command | tr -d '\\r'")
CERT_KEY=$(ssh -o StrictHostKeyChecking=no $K8S_USER@"$MASTER1_IP" "sudo kubeadm init phase upload-certs --upload-certs | tail -n 1 | tr -d '\\r'")

# Download admin.conf locally to distribute it
ssh -o StrictHostKeyChecking=no $K8S_USER@"$MASTER1_IP" "sudo cat /etc/kubernetes/admin.conf" > admin.conf

MASTER_JOIN_CMD="$WORKER_JOIN_CMD --control-plane --certificate-key $CERT_KEY"

# 5. Bootstrap Additional Masters (Quorum)
for MASTER in kubeadm-ha-master-2 kubeadm-ha-master-3; do
  IP=$(get_vm_ip "$MASTER")
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$IP" >/dev/null 2>&1 || true
  log "Uploading join script to $MASTER..."
  scp -o StrictHostKeyChecking=no node-scripts/join_controlplane.sh $K8S_USER@"$IP":~/
  log "Executing master join on $MASTER..."
  ssh -o StrictHostKeyChecking=no $K8S_USER@"$IP" "echo '⏳ Waiting for system to be ready (cloud-init)...'; while ! cloud-init status | grep -q 'done'; do echo -n '.'; sleep 5; done; echo '✅ System Ready!'; while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do echo '⏳ Waiting for apt lock...'; sleep 5; done; chmod +x ~/join_controlplane.sh && sudo ~/join_controlplane.sh '$MASTER_JOIN_CMD'"
done

# 6. Bootstrap Workers
for WORKER in kubeadm-ha-worker-1 kubeadm-ha-worker-2; do
  IP=$(get_vm_ip "$WORKER")
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$IP" >/dev/null 2>&1 || true
  log "Uploading join script and config to $WORKER..."
  scp -o StrictHostKeyChecking=no node-scripts/install_worker.sh admin.conf $K8S_USER@"$IP":~/
  log "Executing worker join on $WORKER..."
  ssh -o StrictHostKeyChecking=no $K8S_USER@"$IP" "echo '⏳ Waiting for system to be ready (cloud-init)...'; while ! cloud-init status | grep -q 'done'; do echo -n '.'; sleep 5; done; echo '✅ System Ready!'; while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do echo '⏳ Waiting for apt lock...'; sleep 5; done; chmod +x ~/install_worker.sh && sudo ~/install_worker.sh '$WORKER_JOIN_CMD'"
done

# 7. Cluster Core Verification
log "Running core cluster verification..."
scp -o StrictHostKeyChecking=no node-scripts/verify_cluster.sh $K8S_USER@"$MASTER1_IP":~/
ssh -o StrictHostKeyChecking=no $K8S_USER@"$MASTER1_IP" "chmod +x ~/verify_cluster.sh && ~/verify_cluster.sh"

log "🎉 Kubeadm HA base deployment is complete!"
log "💡 Optional application workloads (Ingress, CKAD lab, etc.) can be deployed anytime via: ./deploy_apps.sh"
