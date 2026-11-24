#!/usr/bin/env bash
# manage_k8s.sh - Unified management script for Kubeadm HA Cluster on Proxmox
#
# Supports: Setup, Apps, Start, Stop, Delete, SSH-Setup

set -euo pipefail

PROXMOX_IP="192.168.1.35"
PROXMOX_USER="root"
REMOTE_DIR="/root/k8s-deploy-workspace"
TARGET_DIR="scripts-kubeadm"

usage() {
    echo "Usage: $0 <action> [options]"
    echo ""
    echo "Actions:"
    echo "  setup    : Provision VMs and bootstrap HA Kubeadm cluster"
    echo "  apps     : Deploy all GitOps applications & Traefik ingress (via Proxmox jump host)"
    echo "  start    : Power on all cluster VMs"
    echo "  stop     : Gracefully shutdown all cluster VMs"
    echo "  delete   : Destroy all cluster VMs and purge data"
    echo "  ssh-keys : Configure and distribute SSH keys to all VMs"
    echo ""
    echo "Examples:"
    echo "  $0 setup"
    echo "  $0 apps"
    echo "  $0 stop"
    echo "  $0 delete"
    exit 1
}

ACTION="${1:-help}"

if [[ "$ACTION" == "help" || "$ACTION" == "-h" || "$ACTION" == "--help" ]]; then
    usage
fi

if [ ! -d "$TARGET_DIR" ]; then
    echo "❌ Directory $TARGET_DIR does not exist!"
    exit 1
fi

echo "============================================================"
echo "🎯 Action: ${ACTION^^} | Cluster: Kubeadm HA"
echo "📡 Target Proxmox: $PROXMOX_USER@$PROXMOX_IP"
echo "============================================================"

# Helper: Bootstrap / Setup
run_setup() {
    echo "📁 Creating remote workspace on Proxmox..."
    ssh -o StrictHostKeyChecking=no "${PROXMOX_USER}@${PROXMOX_IP}" "mkdir -p ${REMOTE_DIR}"

    echo "📤 Uploading configuration and deployment scripts..."
    scp -r -o StrictHostKeyChecking=no "${TARGET_DIR}/"* "gitops" "${PROXMOX_USER}@${PROXMOX_IP}:${REMOTE_DIR}/"

    echo "⚙️  Executing VM creation script on Proxmox..."
    ssh -o StrictHostKeyChecking=no "${PROXMOX_USER}@${PROXMOX_IP}" "cd ${REMOTE_DIR} && chmod +x 01_create_vms.sh && ./01_create_vms.sh"

    echo "🚀 Running Kubeadm distribution and bootstrap scripts..."
    ssh -o StrictHostKeyChecking=no "${PROXMOX_USER}@${PROXMOX_IP}" "cd ${REMOTE_DIR} && chmod +x 02_distribute_and_run.sh && ./02_distribute_and_run.sh"

    echo "============================================================"
    echo "🎉 Base Kubeadm HA Cluster Provisioned and Ready!"
    echo "👉 To deploy apps and ingress: $0 apps"
    echo "============================================================"
}

# Helper: Deploy Applications (GitOps & Traefik)
run_apps() {
    local PROFILE="${2:-all}"
    echo "📤 Syncing scripts and gitops manifests to Proxmox jump host..."
    ssh -o StrictHostKeyChecking=no "$PROXMOX_USER@$PROXMOX_IP" "mkdir -p $REMOTE_DIR"
    scp -r -o StrictHostKeyChecking=no "${TARGET_DIR}/"* "gitops" "$PROXMOX_USER@$PROXMOX_IP:$REMOTE_DIR/"

    echo "🚀 Running deploy_apps.sh $PROFILE from Proxmox into the cluster..."
    ssh -o StrictHostKeyChecking=no "$PROXMOX_USER@$PROXMOX_IP" "cd $REMOTE_DIR && chmod +x deploy_apps.sh && ./deploy_apps.sh $PROFILE"
}

# Helper: VM Lifecycle operations (start/stop/delete)
run_vm_op() {
    local OP="$1"
    local MSG=""
    local CMD=""

    case "$OP" in
        start)  MSG="Starting";  CMD="qm start" ;;
        stop)   MSG="Stopping";  CMD="qm stop" ;;
        delete) MSG="Destroying"; CMD="qm destroy" ;;
        *) echo "❌ Internal error: Invalid operation $OP"; exit 1 ;;
    esac

    echo "📤 Uploading configuration to Proxmox..."
    ssh -o StrictHostKeyChecking=no "$PROXMOX_USER@$PROXMOX_IP" "mkdir -p $REMOTE_DIR"
    scp -o StrictHostKeyChecking=no "$TARGET_DIR/00_config.sh" "$PROXMOX_USER@$PROXMOX_IP:$REMOTE_DIR/00_config.sh"

    echo "🚀 Executing $OP on Proxmox..."
    ssh -o StrictHostKeyChecking=no "$PROXMOX_USER@$PROXMOX_IP" << EOF
      cd $REMOTE_DIR
      source ./00_config.sh
      
      for NAME in "\${!VMS[@]}"; do
        VMID=\$(get_vm_id "\$NAME")
        if qm status "\$VMID" &>/dev/null; then
          if [[ "$OP" == "delete" ]]; then
            echo "🛑 Stopping VM \$VMID (\$NAME) before destruction..."
            qm stop "\$VMID" || true
            sleep 1
            echo "🔥 Destroying VM \$VMID (\$NAME)..."
            qm destroy "\$VMID" --purge || true
          else
            echo "$MSG VM \$VMID (\$NAME)..."
            \$CMD "\$VMID" || true
          fi
        else
          echo "VM \$VMID (\$NAME) does not exist or is already in target state."
        fi
      done
EOF
}

# Helper: SSH Key Setup directly onto VMs
run_ssh_setup() {
    echo "🔑 Distributing SSH keys via Proxmox..."
    ssh -o StrictHostKeyChecking=no "$PROXMOX_USER@$PROXMOX_IP" << 'EOF'
      K8S_USER="ubuntu"
      BASE_IP="192.168.56"
      declare -A NODES=(
        [kubeadm-ha-master-1]="11"
        [kubeadm-ha-master-2]="12"
        [kubeadm-ha-master-3]="13"
        [kubeadm-ha-worker-1]="21"
        [kubeadm-ha-worker-2]="22"
        [kubeadm-ha-lb]="30"
      )
      for HOSTNAME in "${!NODES[@]}"; do
        IP="${BASE_IP}.${NODES[$HOSTNAME]}"
        echo "Testing SSH to $HOSTNAME ($IP)..."
        ssh -o BatchMode=yes -o ConnectTimeout=5 "${K8S_USER}@${IP}" hostname || true
      done
EOF
}

case "$ACTION" in
    setup)
        run_setup
        ;;
    apps)
        run_apps "$@"
        ;;
    start|stop|delete)
        run_vm_op "$ACTION"
        ;;
    ssh-keys)
        run_ssh_setup
        ;;
    *)
        echo "❌ Unknown action: $ACTION"
        usage
        ;;
esac

echo "============================================================"
echo "✅ Operation ${ACTION^^} completed successfully!"
echo "============================================================"
