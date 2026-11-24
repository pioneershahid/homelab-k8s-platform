#!/usr/bin/env bash
# install_lb.sh - Run this on the Load Balancer node

set -euo pipefail

echo "⏳ Waiting for cloud-init to finish..."
cloud-init status --wait

echo "⏳ Waiting for apt lock..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  sleep 5
done

echo "⚙️ Installing HAProxy on Load Balancer..."

sudo apt-get update
sudo apt-get install -y haproxy

cat <<EOF | sudo tee /etc/haproxy/haproxy.cfg
frontend kubernetes-api
    bind 192.168.56.30:6443
    option tcplog
    mode tcp
    default_backend kubernetes-master-nodes

backend kubernetes-master-nodes
    mode tcp
    balance roundrobin
    option tcp-check
    server kubeadm-ha-master-1 192.168.56.11:6443 check fall 3 rise 2
    server kubeadm-ha-master-2 192.168.56.12:6443 check fall 3 rise 2
    server kubeadm-ha-master-3 192.168.56.13:6443 check fall 3 rise 2

# HTTP Traffic (External -> Ingress)
frontend http-in
    bind *:80
    mode tcp
    option tcplog
    default_backend ingress-http

backend ingress-http
    mode tcp
    balance roundrobin
    server worker-1 192.168.56.21:30080 check
    server worker-2 192.168.56.22:30080 check

# HTTPS Traffic (External -> Ingress)
frontend https-in
    bind *:443
    mode tcp
    option tcplog
    default_backend ingress-https

backend ingress-https
    mode tcp
    balance roundrobin
    server worker-1 192.168.56.21:30443 check
    server worker-2 192.168.56.22:30443 check

# NOTE: Ingress-NGINX is configured to expose fixed NodePorts 30080/30443.
# This ensures the external HAProxy load balancer can forward traffic reliably
# to the Ingress controller on the Kubernetes worker nodes.
EOF

sudo systemctl restart haproxy
sudo systemctl enable haproxy

echo "✅ HAProxy installed and configured successfully."
