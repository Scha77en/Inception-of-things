#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

log() { echo "[k3s-worker] $*"; }

if [[ $(id -u) -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ── Get master IP from command line argument ──
MASTER_IP="${1:-}"
if [[ -z "$MASTER_IP" ]]; then
  echo "Usage: $0 <MASTER_IP>" >&2
  exit 1
fi

# ── Read the node token from the shared folder ──
TOKEN_PATH="/vagrant/confs/token"
if [[ ! -f "$TOKEN_PATH" ]]; then
  echo "Token file not found at $TOKEN_PATH" >&2
  exit 1
fi

K3S_TOKEN="$(cat "$TOKEN_PATH" | tr -d '\n\r')"
if [[ -z "$K3S_TOKEN" ]]; then
  echo "Token file is empty" >&2
  exit 1
fi

log "Master IP: $MASTER_IP"
log "Token (first 8 chars): ${K3S_TOKEN:0:8}..."

# ── Install K3s agent and join the cluster ──
log "Installing K3s agent and joining the master at https://${MASTER_IP}:6443"
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="agent --node-ip 192.168.56.111 --server https://${MASTER_IP}:6443 --flannel-iface=eth1" \
  K3S_TOKEN="$K3S_TOKEN" sh -

log "K3s worker successfully joined the cluster."
