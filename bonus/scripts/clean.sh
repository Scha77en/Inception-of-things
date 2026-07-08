#!/bin/bash

# ─────────────────────────────────────────────────────────────────────────────
#  IoT – Full Cleanup Script
#  Removes everything created by p1, p2, p3 runs
#  Usage: bash cleanup.sh
# ─────────────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }

# ── 1. Kill any port-forwards ─────────────────────────────────────────────────
warn "Killing any running port-forwards..."
pkill -f "kubectl.*port-forward" 2>/dev/null && log "Port-forwards killed." || log "No port-forwards running."

# ── 2. Delete all k3d clusters ───────────────────────────────────────────────
warn "Checking for k3d clusters..."
CLUSTERS=$(k3d cluster list -o json 2>/dev/null | grep '"name"' | sed 's/.*"name": "\(.*\)".*/\1/' | tr -d ' ')
if [ -n "$CLUSTERS" ]; then
    for cluster in $CLUSTERS; do
        warn "Deleting k3d cluster: $cluster"
        k3d cluster delete "$cluster"
        log "Cluster '$cluster' deleted."
    done
else
    log "No k3d clusters found."
fi

# ── 3. Delete all k3d registries ─────────────────────────────────────────────
warn "Checking for k3d registries..."
REGISTRIES=$(k3d registry list -o json 2>/dev/null | grep '"name"' | sed 's/.*"name": "\(.*\)".*/\1/' | tr -d ' ')
if [ -n "$REGISTRIES" ]; then
    for reg in $REGISTRIES; do
        warn "Deleting k3d registry: $reg"
        k3d registry delete "$reg" 2>/dev/null
        log "Registry '$reg' deleted."
    done
else
    log "No k3d registries found."
fi

# ── 4. Remove leftover k3d Docker containers ─────────────────────────────────
warn "Removing any leftover k3d Docker containers..."
K3D_CONTAINERS=$(docker ps -a --filter "label=app=k3d" -q 2>/dev/null)
if [ -n "$K3D_CONTAINERS" ]; then
    docker rm -f $K3D_CONTAINERS
    log "Leftover k3d containers removed."
else
    log "No leftover k3d containers."
fi

# ── 5. Remove leftover k3d Docker networks ───────────────────────────────────
warn "Removing any leftover k3d Docker networks..."
K3D_NETWORKS=$(docker network ls --filter "label=app=k3d" -q 2>/dev/null)
if [ -n "$K3D_NETWORKS" ]; then
    docker network rm $K3D_NETWORKS 2>/dev/null
    log "Leftover k3d networks removed."
else
    log "No leftover k3d networks."
fi

# ── 6. Remove leftover k3d Docker volumes ────────────────────────────────────
warn "Removing any leftover k3d Docker volumes..."
K3D_VOLUMES=$(docker volume ls --filter "label=app=k3d" -q 2>/dev/null)
if [ -n "$K3D_VOLUMES" ]; then
    docker volume rm $K3D_VOLUMES 2>/dev/null
    log "Leftover k3d volumes removed."
else
    log "No leftover k3d volumes."
fi

# ── 7. Clean up kubectl config ────────────────────────────────────────────────
warn "Cleaning up kubectl contexts..."
for ctx in $(kubectl config get-contexts -o name 2>/dev/null | grep "k3d"); do
    kubectl config delete-context "$ctx" 2>/dev/null
    log "Deleted kubectl context: $ctx"
done
for cluster in $(kubectl config get-clusters 2>/dev/null | grep "k3d"); do
    kubectl config delete-cluster "$cluster" 2>/dev/null
    log "Deleted kubectl cluster config: $cluster"
done
for user in $(kubectl config get-users 2>/dev/null | grep "k3d"); do
    kubectl config delete-user "$user" 2>/dev/null
    log "Deleted kubectl user: $user"
done

# ── 8. Kill any vagrant VMs (p1/p2) ──────────────────────────────────────────
if command -v vagrant &>/dev/null; then
    warn "Checking for running Vagrant VMs..."
    # p1
    if [ -f "$HOME/p1/Vagrantfile" ]; then
        warn "Destroying p1 Vagrant VMs..."
        (cd "$HOME/p1" && vagrant destroy -f 2>/dev/null) && log "p1 VMs destroyed." || true
    fi
    # p2
    if [ -f "$HOME/p2/Vagrantfile" ]; then
        warn "Destroying p2 Vagrant VMs..."
        (cd "$HOME/p2" && vagrant destroy -f 2>/dev/null) && log "p2 VMs destroyed." || true
    fi
    # bonus
    if [ -f "$HOME/bonus/Vagrantfile" ]; then
        warn "Destroying bonus Vagrant VMs..."
        (cd "$HOME/bonus" && vagrant destroy -f 2>/dev/null) && log "bonus VMs destroyed." || true
    fi
else
    log "Vagrant not installed — skipping."
fi

# ── 9. Prune unused Docker resources ─────────────────────────────────────────
warn "Pruning unused Docker resources (stopped containers, dangling images)..."
docker container prune -f 2>/dev/null
docker network prune -f 2>/dev/null
docker volume prune -f 2>/dev/null
log "Docker pruned."

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "CLEANUP COMPLETE — system is clean"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log "You can now run: bash scripts/install.sh"
