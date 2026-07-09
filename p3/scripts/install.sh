#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
fail() { echo -e "${RED}[✘] $1${NC}"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 1 – Docker
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo usermod -aG docker "$USER"
    sudo systemctl enable --now docker
    log "Docker installed."
else
    log "Docker already installed: $(docker --version)"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 2 – kubectl
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v kubectl &>/dev/null; then
    log "Installing kubectl..."
    KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
    curl -fsSLo /tmp/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x /tmp/kubectl
    sudo mv /tmp/kubectl /usr/local/bin/kubectl
    log "kubectl installed."
else
    log "kubectl already installed."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 3 – k3d
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v k3d &>/dev/null; then
    log "Installing k3d..."
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    log "k3d installed."
else
    log "k3d already installed."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 4 – Delete existing cluster if any
# ─────────────────────────────────────────────────────────────────────────────
if k3d cluster list | grep -q "iot-cluster"; then
    warn "Existing iot-cluster found. Deleting it..."
    k3d cluster delete iot-cluster
    log "Old cluster deleted."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 5 – Create k3d cluster
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/../confs/k3d-config.yaml"

[ -f "$CONFIG" ] || fail "k3d-config.yaml not found at: $CONFIG"

log "Creating k3d cluster..."
k3d cluster create --config "$CONFIG"

log "Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s
kubectl get nodes -o wide

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 6 – Install Argo CD
# ─────────────────────────────────────────────────────────────────────────────
log "Creating argocd namespace..."
kubectl create namespace argocd

log "Installing Argo CD..."
kubectl apply -n argocd --server-side \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

log "Waiting for Argo CD server to be ready (up to 5 min)..."
kubectl -n argocd wait \
    --for=condition=available deployment/argocd-server \
    --timeout=300s
log "Argo CD is ready."

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 7 – Deploy the application via Argo CD
# ─────────────────────────────────────────────────────────────────────────────
APP_CR="$SCRIPT_DIR/../confs/argocd-application.yaml"

[ -f "$APP_CR" ] || fail "argocd-application.yaml not found at: $APP_CR"

log "Applying Argo CD Application..."
kubectl apply -f "$APP_CR"

log "Waiting for wil-playground pod in dev namespace (up to 3 min)..."
for i in $(seq 1 36); do
    READY=$(kubectl get pods -n dev --no-headers 2>/dev/null \
            | grep "wil-playground" | grep "Running" | wc -l)
    [ "$READY" -ge 1 ] && break
    echo "  ... still waiting ($((i * 5))s)"
    sleep 5
done

# ─────────────────────────────────────────────────────────────────────────────
#  DONE
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "SETUP COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo ">> Namespaces:"
kubectl get ns

echo ""
echo ">> Pods in dev:"
kubectl get pods -n dev

echo ""
echo ">> Argo CD credentials:"
PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)
echo "   Username : admin"
echo "   Password : $PASS"

echo ""
warn "To access Argo CD UI:"
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
HOST_IP=$(hostname -I | awk '{print $1}')
echo "   Then open: https://$HOST_IP:8080"

echo ""
warn "To test the app:"
echo "   curl http://localhost:8888/"

echo ""
log "Done!"
