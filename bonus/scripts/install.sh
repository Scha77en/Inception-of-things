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
#  STEP X – Helm
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v helm &> /dev/null; then
    log "Installing Helm..."
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh
    ./get_helm.sh
    rm get_helm.sh
else
    log "4. ✅ Helm is already installed. Skipping."
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
#  STEP X – Install Gitlab
# ─────────────────────────────────────────────────────────────────────────────
kubectl create namespace gitlab
log "Deploying External Databases (PostgreSQL & Redis)..."
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

helm upgrade --install gitlab-postgresql bitnami/postgresql \
  --namespace gitlab \
  --set auth.database=gitlabhq_production \
  --set auth.username=gitlab \
  --set auth.password=gitlabpassword \
  --set auth.postgresPassword=postgrespassword \
  --set primary.persistence.enabled=false \
  --set primary.resourcesPreset=none \
  --set primary.livenessProbe.initialDelaySeconds=120 \
  --set primary.readinessProbe.initialDelaySeconds=120

helm upgrade --install gitlab-redis bitnami/redis \
  --namespace gitlab \
  --set architecture=standalone \
  --set auth.enabled=false \
  --set master.persistence.enabled=false \
  --set master.livenessProbe.initialDelaySeconds=120 \
  --set master.readinessProbe.initialDelaySeconds=120

log "   -> Waiting for databases to initialize..."
kubectl wait --namespace gitlab --for=condition=ready pod --selector=app.kubernetes.io/name=postgresql --timeout=300s
kubectl wait --namespace gitlab --for=condition=ready pod --selector=app.kubernetes.io/name=redis --timeout=300s

log "Installing GitLab (Pinned to v10.1.0)..."
helm repo add gitlab https://charts.gitlab.io/
helm repo update

helm upgrade --install gitlab gitlab/gitlab \
  --namespace gitlab \
  --timeout 1800s \
  -f confs/gitlab-value.yml
kubectl rollout status deployment/gitlab-webservice-default -n gitlab --timeout=900s
kubectl patch svc gitlab-webservice-default -n gitlab -p '{"spec": {"type": "LoadBalancer"}}'
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
#  STEP X – CREATE THE GITLAB LOCAL REPO
# ─────────────────────────────────────────────────────────────────────────────
GitLabPass=$(kubectl -n gitlab get secret gitlab-gitlab-initial-root-password -o jsonpath="{.data.password}" | base64 -d)
TARGET_APP_REPO="https://github.com/Scha77en/aouhbi-k3d-argo-cd.git"
REPO_NAME="aouhbi-k3d-argo-cd"
rm -rf $REPO_NAME 
git clone $TARGET_APP_REPO
cd "$REPO_NAME" || { echo "❌ Source directory $REPO_NAME not found"; exit 1; }

rm -rf .git
git init
git checkout -b master 2>/dev/null || git checkout -b main
git add .
git commit -m "Automated deployment commit"
git push -f "http://root:${GitLabPass}@localhost:8181/root/${REPO_NAME}.git" HEAD:master
cd - > /dev/null

echo "11. Authenticating ArgoCD to read the new Repository..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  url: http://gitlab-webservice-default.gitlab.svc.cluster.local:8181/root/${REPO_NAME}.git
  username: root
  password: ${GitLabPass}
EOF

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
kubectl -n dev port-forward svc/wil-playground-service 8888:8888 --address 0.0.0.0 &
echo "   curl http://134.209.206.60:8888/"
echo ""

echo ">> Gitlab credentials:"
echo "   Username : root"
echo "   Password : ${GitLabPass}"
echo ""
sleep 2
echo "   curl: https://134.209.206.60:8181"
echo ""
log "Done!"
