# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    k3s-server.sh                                      :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: shamsate <shamsate@student.1337.ma>        +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/11 15:45:11 by shamsate          #+#    #+#              #
#    Updated: 2026/06/11 15:48:12 by shamsate         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

export DEBIAN_FRONTEND=noninteractive

log() { echo "[k3s-server] $*"; }

if [[ $(id -u) -ne 0 ]]; then
	echo "This script must be run as root" >&2
	exit 1
fi

log "Updating apt and installing prerequisites"
apt-get update
apt-get install -y curl net-tools

log "Installing k3s server"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--node-ip=192.168.56.110 --write-kubeconfig-mode 644" sh -s -

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

log "Waiting for Kubernetes node readiness"
timeout=180
elapsed=0
interval=3
until kubectl wait --for=condition=Ready node --all --timeout=5s >/dev/null 2>&1; do
	if [[ $elapsed -ge $timeout ]]; then
		echo "Timed out waiting for K3s node readiness" >&2
		kubectl get nodes -o wide || true
		exit 1
	fi
	sleep $interval
	elapsed=$((elapsed + interval))
done

log "Applying application confs"
kubectl apply -f /vagrant/confs/apps.yaml

log "P2 K3s server is ready"