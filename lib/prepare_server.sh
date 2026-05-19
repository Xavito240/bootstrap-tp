#!/usr/bin/env bash
# lib/prepare_server.sh
# Préparation du serveur distant : Docker, k3s, kubectl, ufw.
# Ce script est envoyé via SSH par bootstrap.sh.
# Idempotent : peut être relancé sans casser ce qui existe.

set -euo pipefail

# ----- Helpers --------------------------------------------------------------
log()  { echo "[remote] $*"; }
ok()   { echo "[remote] ✓ $*"; }
warn() { echo "[remote] ⚠ $*"; }

# ----- 1. Mise à jour APT minimale ------------------------------------------
if ! command -v curl >/dev/null 2>&1; then
  log "Installation des paquets de base…"
  sudo apt-get update -qq
  sudo apt-get install -y -qq curl ca-certificates gnupg lsb-release
fi
ok "Paquets de base présents"

# ----- 2. Docker (utile pour debug local mais non indispensable pour k3s) ---
if ! command -v docker >/dev/null 2>&1; then
  log "Installation de Docker…"

  # Clé GPG officielle Docker
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  # Repo Docker
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin

  # Permettre à l'utilisateur courant d'utiliser docker sans sudo
  sudo usermod -aG docker "$USER"

  ok "Docker installé"
else
  ok "Docker déjà installé ($(docker --version))"
fi

# ----- 3. k3s ---------------------------------------------------------------
if ! command -v k3s >/dev/null 2>&1; then
  log "Installation de k3s…"

  # Le script officiel k3s, avec write-kubeconfig-mode pour le rendre lisible
  curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -

  # Attendre que k3s soit prêt
  log "Attente que k3s soit prêt…"
  for _ in {1..30}; do
    if sudo kubectl get nodes 2>/dev/null | grep -q " Ready "; then
      break
    fi
    sleep 2
  done

  ok "k3s installé"
else
  ok "k3s déjà installé"
fi

# Vérifier que k3s tourne
if ! sudo systemctl is-active --quiet k3s; then
  warn "k3s n'est pas actif, démarrage…"
  sudo systemctl start k3s
fi
ok "k3s actif"

# ----- 4. kubectl pour l'utilisateur courant --------------------------------
mkdir -p ~/.kube
if [[ ! -f ~/.kube/config ]] || ! grep -q "k3s" ~/.kube/config 2>/dev/null; then
  log "Configuration du kubeconfig pour ${USER}…"
  sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
  sudo chown "$USER:$USER" ~/.kube/config
  chmod 600 ~/.kube/config
fi
export KUBECONFIG=~/.kube/config

if kubectl get nodes >/dev/null 2>&1; then
  ok "kubectl fonctionne ($(kubectl get nodes --no-headers | wc -l) nœud(s))"
else
  warn "kubectl ne fonctionne pas — vérification manuelle requise"
fi

# ----- 5. Helm (utile pour des perspectives, non bloquant) -----------------
if ! command -v helm >/dev/null 2>&1; then
  log "Installation de Helm…"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash > /dev/null
  ok "Helm installé"
else
  ok "Helm déjà installé"
fi

# ----- 6. metrics-server (pour kubectl top et HPA) --------------------------
# k3s l'inclut souvent par défaut, on vérifie
if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
  log "Installation de metrics-server…"
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  # k3s nécessite --kubelet-insecure-tls (certificats auto-signés)
  kubectl patch deployment metrics-server -n kube-system --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' || true
  ok "metrics-server installé"
else
  ok "metrics-server déjà présent"
fi

# ----- 7. UFW (firewall) ----------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  if ! sudo ufw status | grep -q "Status: active"; then
    log "Configuration de UFW…"
    sudo ufw --force default deny incoming
    sudo ufw --force default allow outgoing
    sudo ufw allow 22/tcp comment "SSH"
    sudo ufw allow 80/tcp comment "HTTP"
    sudo ufw allow 443/tcp comment "HTTPS"
    sudo ufw allow 6443/tcp comment "k8s API"
    sudo ufw --force enable
    ok "UFW configuré et actif"
  else
    ok "UFW déjà actif"
  fi
fi

# ----- 8. fail2ban ----------------------------------------------------------
if ! command -v fail2ban-server >/dev/null 2>&1; then
  log "Installation de fail2ban…"
  sudo apt-get install -y -qq fail2ban
  sudo systemctl enable --now fail2ban
  ok "fail2ban installé et actif"
else
  ok "fail2ban déjà présent"
fi

# ----- 9. Récapitulatif -----------------------------------------------------
echo
echo "═══════════════════════════════════════════════════════════"
echo "  Serveur préparé — récapitulatif"
echo "═══════════════════════════════════════════════════════════"
echo "  Hostname     : $(hostname)"
echo "  OS           : $(lsb_release -ds 2>/dev/null || uname -s)"
echo "  Kernel       : $(uname -r)"
echo "  Docker       : $(docker --version 2>/dev/null | head -c 60 || echo 'non installé')"
echo "  k3s          : $(k3s --version 2>/dev/null | head -1 || echo 'non installé')"
echo "  kubectl      : $(kubectl version --client 2>/dev/null | head -1 || echo 'non installé')"
echo "  Helm         : $(helm version --short 2>/dev/null || echo 'non installé')"
echo "  Nœuds K8s    : $(kubectl get nodes --no-headers 2>/dev/null | wc -l)"
echo "═══════════════════════════════════════════════════════════"
