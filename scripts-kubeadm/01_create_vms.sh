#!/usr/bin/env bash
# 01_create_vms.sh - Proxmox automation for Kubeadm HA Cluster

set -euo pipefail
source ./00_config.sh

# Ensure the Proxmox bridge exists and has the Gateway IP
echo "🌐 Configuring Proxmox network and NAT on $BRIDGE..."
if ! ip link show "$BRIDGE" &>/dev/null; then
  echo "🛠️  Bridge $BRIDGE not found. Creating it..."
  ip link add name "$BRIDGE" type bridge
fi
ip addr add ${GW}/24 dev $BRIDGE || true
ip link set $BRIDGE up

# Enable IP Forwarding and NAT (Masquerade) to give VMs internet access
sysctl -w net.ipv4.ip_forward=1 >/dev/null
# We assume vmbr0 is the internet-facing bridge. 
# We use the subnet from the GW variable (e.g., 192.168.56.0/24)
SUBNET=$(echo $GW | cut -d'.' -f1-3).0/24
iptables -t nat -A POSTROUTING -s "$SUBNET" -o vmbr0 -j MASQUERADE || true

HOSTS_FILE_CONTENT=$(cat <<EOF
127.0.0.1 localhost
::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

192.168.56.11 kubeadm-ha-master-1
192.168.56.12 kubeadm-ha-master-2
192.168.56.13 kubeadm-ha-master-3
192.168.56.21 kubeadm-ha-worker-1
192.168.56.22 kubeadm-ha-worker-2
192.168.56.30 kubeadm-ha-lb
EOF
)

for NAME in "${!VMS[@]}"; do
  IP=$(get_vm_ip "$NAME")
  VMID=$(get_vm_id "$NAME")
  CLOUD_INIT="/tmp/${NAME}-cloudinit.yaml"

  echo "Creating VM $NAME at $IP (ID: $VMID)..."

  # If VM exists, delete it first to ensure a clean slate
  if qm status "$VMID" &>/dev/null; then
    echo "⚠️  VMID $VMID exists. Deleting..."
    qm stop "$VMID" || true
    sleep 2
    qm destroy "$VMID" --purge || true
    sleep 2
  fi

  cat <<EOF > "$CLOUD_INIT"
#cloud-config
hostname: $NAME
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$SSH_KEY")

write_files:
  - path: /etc/hosts
    permissions: '0644'
    content: |
$(echo "$HOSTS_FILE_CONTENT" | sed 's/^/      /')

  - path: /etc/resolv.conf
    content: |
      nameserver $DNS

  - path: /home/ubuntu/.ssh/config
    content: |
      Host *
        StrictHostKeyChecking no
        UserKnownHostsFile=/dev/null
    owner: ubuntu:ubuntu
    permissions: '0600'

runcmd:
  - systemctl stop apt-daily.timer apt-daily-upgrade.timer || true
  - systemctl disable apt-daily.timer apt-daily-upgrade.timer || true
  - systemctl kill --kill-who=all apt-daily.service || true
  - systemctl disable systemd-resolved
  - systemctl stop systemd-resolved
  - unlink /etc/resolv.conf || true
  - echo "nameserver $DNS" > /etc/resolv.conf
  - while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
  - apt-get update
  - apt-get install -y curl openssl sshpass
  - sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - sed -i 's/^KbdInteractiveAuthentication no/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart sshd
  - |
    PRIMARY_IP="\$(ip -4 addr show | grep 'inet' | egrep -v '(dynamic|127\\.|docker|br-)' | awk '{print \$2}' | cut -d/ -f1)"
    echo "PRIMARY_IP=\$PRIMARY_IP" >> /etc/environment
    echo "ARCH=amd64" >> /etc/environment
EOF

  mkdir -p /var/lib/vz/snippets
  cp "$CLOUD_INIT" "/var/lib/vz/snippets/${NAME}-cloudinit.yaml"

  # Role-specific sizing: Workers need more disk/RAM for workloads (Wazuh, Frigate, Immich)
  CURRENT_MEM=$VM_MEM
  CURRENT_DISK=$VM_DISK_SIZE
  if [[ "$NAME" == *"worker"* ]]; then
    CURRENT_MEM=4096
    CURRENT_DISK="30G"
  elif [[ "$NAME" == *"master"* ]]; then
    CURRENT_MEM=3072
    CURRENT_DISK="10G"
  fi

  # Proxmox VM provisioning
  qm clone "$TEMPLATE_ID" "$VMID" --name "$NAME"
  qm resize "$VMID" scsi0 "$CURRENT_DISK"

  qm set "$VMID" \
    --cpu host \
    --memory $CURRENT_MEM --cores $VM_CPU \
    --net0 virtio,bridge=$BRIDGE \
    --ipconfig0 ip=$IP/24,gw=$GW \
    --ciuser $K8S_USER \
    --cipassword "$K8S_PASSWORD" \
    --sshkeys "$SSH_KEY" \
    --cicustom "user=local:snippets/${NAME}-cloudinit.yaml" \
    --scsihw virtio-scsi-pci \
    --boot order=scsi0 \
    --agent enabled=1

  # Add second NIC for LB node (External Access)
  if [[ "$NAME" == *"lb"* ]]; then
    echo "🌐 Adding external interface (vmbr0) to $NAME..."
    qm set "$VMID" --net1 virtio,bridge=$EXTERNAL_BRIDGE
    qm set "$VMID" --ipconfig1 ip=$EXTERNAL_LB_IP/24
  fi

  qm start "$VMID"
  echo "$NAME ($IP) started."

  # Update /etc/hosts on Proxmox for easier SSH
  sed -i "/$NAME/d" /etc/hosts
  echo "$IP $NAME" >> /etc/hosts
done
