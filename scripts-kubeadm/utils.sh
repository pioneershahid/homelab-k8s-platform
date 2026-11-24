#!/usr/bin/env bash
# utils.sh

log() {
  echo -e "\n[ $(date +"%H:%M:%S") ] 👉 \033[1;34m$*\033[0m"
}

fail() {
  echo -e "❌ \033[1;31m$*\033[0m" >&2
  exit 1
}

retry_ssh() {
  local IP=$1
  local RETRIES=15
  local DELAY=5
  for i in $(seq 1 $RETRIES); do
    log "🔌 Attempting SSH to $IP (try $i/$RETRIES)..."
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$K8S_USER@$IP" true 2>/dev/null; then
      log "✅ SSH ready for $IP"
      return 0
    fi
    sleep $DELAY
  done
  echo "❌ SSH connection to $IP failed after $RETRIES attempts."
  exit 1
}