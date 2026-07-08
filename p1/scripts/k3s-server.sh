#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

log() { echo "[k3s-server] $*"; }

if [[ $(id -u) -ne 0 ]]; then
  echo "This script must be run as root" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ── Install K3s on the control plane node ──
log "Installing K3s server..."

# Force K3s to bind to the private network IP instead of the NAT IP
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="server --node-ip 192.168.56.110 --bind-address 192.168.56.110 --tls-san=192.168.1.110 --flannel-iface=eth1" sh -

# ── Set up kubeconfig for the 'vagrant' user ──
log "Setting up kubeconfig for vagrant user"
mkdir -p /home/vagrant/.kube
cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

# Automatically point kubectl to the unlocked config file every time the user logs in
echo "export KUBECONFIG=/home/vagrant/.kube/config" >> /home/vagrant/.bashrc

# ── Share the node token so the worker can join ──
log "Copying node token to /vagrant/confs/token"
mkdir -p /vagrant/confs
cp /var/lib/rancher/k3s/server/node-token /vagrant/confs/token

log "K3s server installation completed successfully."
