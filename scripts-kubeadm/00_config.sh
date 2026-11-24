#!/usr/bin/env bash
# 00_config.sh - Centralized configuration for Kubeadm HA on Proxmox

set -euo pipefail

# vm user root and password root checked and working
# Load .env file if present in workspace root or current directory
if [ -f "$(dirname "$0")/../.env" ]; then
  set -a
  source "$(dirname "$0")/../.env"
  set +a
elif [ -f "$(dirname "$0")/.env" ]; then
  set -a
  source "$(dirname "$0")/.env"
  set +a
fi

# Proxmox Defaults
TEMPLATE_ID=800
TEMPLATE_BRIDGE="vmbr1"
GW="192.168.56.1"
DNS="8.8.8.8"
K8S_USER="ubuntu" 
K8S_PASSWORD="Password123!" # Change this!
DOCKER_USER="${DOCKER_USER:-pioneershahid}"
DOCKER_TOKEN="${DOCKER_TOKEN:-}" # Pass via environment variable or prompt before push
BRIDGE="vmbr1"
VM_CPU=2
VM_MEM=4096
VM_DISK_SIZE="20G"
STORAGE="local"

ADMIN_USER="${ADMIN_USER:-$(whoami)}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa.pub}"

# VM Configuration Mapping
# Format: [name]="ip_suffix vmid"
declare -A VMS=(
  [kubeadm-ha-master-1]="11 311"
  [kubeadm-ha-master-2]="12 312"
  [kubeadm-ha-master-3]="13 313"
  [kubeadm-ha-worker-1]="21 321"
  [kubeadm-ha-worker-2]="22 322"
  [kubeadm-ha-lb]="30 330"
)

# External Network (Home Network) - For Application Access
EXTERNAL_BRIDGE="vmbr0"
EXTERNAL_LB_IP="192.168.1.150" # Change this to an available IP on your home network

# Helpers for lookup
get_vm_ip() {
  local name=$1
  local ip_suffix="${VMS[$name]%% *}"
  echo "192.168.56.$ip_suffix"
}

get_vm_id() {
  local name=$1
  local id_str="${VMS[$name]##* }"
  echo "$id_str"
}

export KUBERNETES_PUBLIC_ADDRESS="192.168.56.30"
export EXTERNAL_LB_IP
