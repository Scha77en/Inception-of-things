#!/bin/bash
set -e

# ─────────────────────────────────────────────────────────────────────────────
#  IoT – Part 3  |  Full install & setup script
#  Usage: bash install.sh
# ─────────────────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✔] $1${NC}"; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }
fail() { echo -e "${RED}[✘] $1${NC}"; exit 1; }

# ── 0. Must NOT be run as root ────────────────────────────────────────────────
[ "$EUID" -eq 0 ] && fail "Run as a normal user with sudo rights, not as root."

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 1 – Docker
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log "Installing Docker..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io
    sudo usermod -aG docker "$USER"
    log "Docker installed."
else
    log "Docker already installed: $(docker --version)"
fi

sudo systemctl enable --now docker &>/dev/null || true

# If we can't reach docker yet (group membership), re-exec under sg docker
if ! docker info &>/dev/null 2>&1; then
    warn "Applying docker group membership for this session via sg..."
    exec sg docker "$0" "$@"
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
    log "kubectl ${KUBECTL_VERSION} installed."
else
    log "kubectl already present: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 3 – k3d
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v k3d &>/dev/null; then
    log "Installing k3d..."
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    log "k3d installed: $(k3d version | head -1)"
else
    log "k3d already present: $(k3d version | head -1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 4 – Argo CD CLI
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v argocd &>/dev/null; then
    log "Installing Argo CD CLI..."
    ARGOCD_VERSION=$(curl -fsSL \
        https://api.github.com/repos/argoproj/argo-cd/releases/latest \
        | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    curl -fsSLo /tmp/argocd \
        "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-amd64"
    chmod +x /tmp/argocd
    sudo mv /tmp/argocd /usr/local/bin/argocd
    log "Argo CD CLI ${ARGOCD_VERSION} installed."
else
    log "Argo CD CLI already present."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 5 – Tear down any existing iot-cluster
# ─────────────────────────────────────────────────────────────────────────────
if k3d cluster list 2>/dev/null | grep -q "iot-cluster"; then
    warn "Existing iot-cluster found – deleting it first..."
    k3d cluster delete iot-cluster
    log "Old cluster deleted."
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 6 – Create k3d cluster
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../confs/k3d-config.yaml"

[ -f "$CONFIG_FILE" ] || fail "k3d-config.yaml not found at: $CONFIG_FILE"

log "Creating k3d cluster from config..."
k3d cluster create --config "$CONFIG_FILE"
log "Cluster created."

log "Waiting for all nodes to be Ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl get nodes -o wide

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 7 – Install Argo CD
# ─────────────────────────────────────────────────────────────────────────────
log "Creating argocd namespace and deploying Argo CD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

log "Waiting for argocd-server (up to 3 min)..."
kubectl -n argocd wait \
    --for=condition=available deployment/argocd-server \
    --timeout=180s
log "Argo CD server is up."

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 8 – Apply Application CR
# ─────────────────────────────────────────────────────────────────────────────
APP_CR="${SCRIPT_DIR}/../confs/argocd-application.yaml"
[ -f "$APP_CR" ] || fail "argocd-application.yaml not found at: $APP_CR"

log "Applying Argo CD Application CR..."
kubectl apply -f "$APP_CR"

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 9 – Wait for the dev pod
# ─────────────────────────────────────────────────────────────────────────────
log "Waiting for wil-playground pod in dev namespace (up to 3 min)..."
for i in $(seq 1 36); do
    READY=$(kubectl get pods -n dev --no-headers 2>/dev/null \
            | grep "wil-playground" | grep "Running" | wc -l)
    [ "$READY" -ge 1 ] && break
    echo "  ... still waiting ($((i * 5))s)"
    sleep 5
done

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 10 – Final summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "SETUP COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo ">> All namespaces:"
kubectl get ns
echo ""
echo ">> Pods in dev:"
kubectl get pods -n dev
echo ""
echo ">> Argo CD credentials:"
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)
echo "   Username : admin"
echo "   Password : ${ARGOCD_PASS}"
echo ""
warn "Argo CD UI:"
kubectl -n argocd port-forward svc/argocd-server 8080:443 --address 0.0.0.0 &

sleep 2
echo "   Open: https://134.209.206.60:8080"
echo ""
warn "Test the app:"
echo ""
log "Done!"
