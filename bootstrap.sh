#!/usr/bin/env bash
# =============================================================================
#  bootstrap.sh
#  -----------------------------------------------------------------------------
#  Déploie le TP DevSecOps de A à Z en un seul script.
#
#  Pré-requis (vérifiés par le script) :
#    - git, gh (GitHub CLI), docker, ssh, curl, jq
#    - gum (charm.sh/gum) pour le TUI — installation proposée si manquant
#    - claude (Claude Code CLI) — invoqué pour les skills
#    - un serveur SSH-accessible avec sudo
#    - un compte GitHub et un compte Docker Hub
#
#  Le script est idempotent : un fichier .bootstrap-state suit la progression.
#  Relancer le script reprend exactement où il s'était arrêté.
#  Pour repartir de zéro : ./bootstrap.sh --reset
#
#  Usage :
#    ./bootstrap.sh                       # exécution normale (TUI gum)
#    ./bootstrap.sh --config FILE         # mode non-interactif (CI/CD)
#    ./bootstrap.sh --reset               # efface l'état et recommence
#    ./bootstrap.sh --status              # affiche les étapes restantes
#    ./bootstrap.sh --help                # affiche cette aide
# =============================================================================

set -euo pipefail

# ----- Palette projet -------------------------------------------------------
readonly C_NAVY_HEX='#1E2761'
readonly C_CORAL_HEX='#F96167'
readonly C_GREEN_HEX='#2C8B5A'

# ----- Couleurs ANSI (fallback) ---------------------------------------------
readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'
readonly C_NAVY='\033[38;5;25m'
readonly C_CORAL='\033[38;5;203m'
readonly C_GREEN='\033[38;5;35m'
readonly C_YELLOW='\033[38;5;214m'
readonly C_RED='\033[38;5;160m'
readonly C_BLUE='\033[38;5;39m'

# ----- Détection / installation de gum --------------------------------------
HAS_GUM=0
ensure_gum() {
  if command -v gum >/dev/null 2>&1; then
    HAS_GUM=1
    return 0
  fi

  echo
  echo -e "${C_YELLOW}⚠${C_RESET}  gum n'est pas installé (TUI dégradée)."
  echo "    gum est un petit outil TUI (charm.sh/gum) qui rend les prompts beaucoup plus agréables."
  echo

  # En mode non-interactif (--config), on continue sans poser de question.
  if [[ "${BOOTSTRAP_NONINTERACTIVE:-0}" == "1" ]]; then
    echo -e "${C_DIM}Mode non-interactif : on continue sans gum.${C_RESET}"
    return 0
  fi

  local installer=""
  if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    installer="brew install gum"
  elif command -v apt >/dev/null 2>&1; then
    installer="sudo mkdir -p /etc/apt/keyrings && curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg && echo 'deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *' | sudo tee /etc/apt/sources.list.d/charm.list && sudo apt update && sudo apt install -y gum"
  fi

  if [[ -n "$installer" ]]; then
    read -r -p "Installer gum maintenant ? [Y/n] " ans
    ans="${ans:-y}"
    ans=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
    if [[ "$ans" == "y" || "$ans" == "yes" || "$ans" == "o" ]]; then
      eval "$installer"
      if command -v gum >/dev/null 2>&1; then
        HAS_GUM=1
        echo -e "${C_GREEN}✓${C_RESET}  gum installé"
        return 0
      fi
      echo -e "${C_RED}✗${C_RESET}  Installation de gum échouée, fallback texte."
    fi
  else
    echo "    Installation manuelle : https://github.com/charmbracelet/gum#installation"
  fi
}

# ----- Helpers UI (gum + fallback) ------------------------------------------
ui_step() {
  # Encadré d'étape
  local title="$*"
  if (( HAS_GUM == 1 )); then
    gum style \
      --border rounded \
      --border-foreground "$C_NAVY_HEX" \
      --foreground "$C_NAVY_HEX" \
      --bold \
      --padding "0 2" \
      --margin "1 0 0 0" \
      "${title}"
  else
    echo -e "\n${C_NAVY}${C_BOLD}━━━ ${title} ━━━${C_RESET}"
  fi
}

ui_info()  { echo -e "${C_BLUE}ℹ${C_RESET}  $*"; }
ui_ok()    { echo -e "${C_GREEN}✓${C_RESET}  $*"; }
ui_warn()  { echo -e "${C_YELLOW}⚠${C_RESET}  $*"; }
ui_err()   { echo -e "${C_RED}✗${C_RESET}  $*" >&2; }
ui_skip()  { echo -e "${C_DIM}↷  $* (déjà fait)${C_RESET}"; }

ui_input() {
  # ui_input VAR_NAME "Question" [default]
  local var_name="$1"
  local question="$2"
  local default="${3:-}"
  local current="${!var_name:-}"

  if [[ -n "$current" ]]; then
    ui_skip "${var_name} déjà défini (${current})"
    return 0
  fi

  local answer=""
  if (( HAS_GUM == 1 )); then
    if [[ -n "$default" ]]; then
      answer=$(gum input \
        --header "${question}" \
        --placeholder "${default}" \
        --value "${default}" \
        --prompt "› " \
        --prompt.foreground "$C_CORAL_HEX" \
        --header.foreground "$C_NAVY_HEX")
    else
      answer=$(gum input \
        --header "${question}" \
        --prompt "› " \
        --prompt.foreground "$C_CORAL_HEX" \
        --header.foreground "$C_NAVY_HEX")
    fi
  else
    if [[ -n "$default" ]]; then
      echo -ne "${C_CORAL}?${C_RESET}  ${question} [${C_DIM}${default}${C_RESET}] "
    else
      echo -ne "${C_CORAL}?${C_RESET}  ${question} "
    fi
    read -r answer
    answer="${answer:-$default}"
  fi

  if [[ -z "$answer" ]]; then
    ui_err "Valeur requise pour ${var_name}"
    exit 1
  fi

  printf -v "$var_name" '%s' "$answer"
  # shellcheck disable=SC2163
  export "${var_name?}"
}

ui_password() {
  # ui_password VAR_NAME "Question"
  local var_name="$1"
  local question="$2"
  local current="${!var_name:-}"

  if [[ -n "$current" ]]; then
    ui_skip "${var_name} déjà défini (****)"
    return 0
  fi

  local answer=""
  if (( HAS_GUM == 1 )); then
    answer=$(gum input \
      --password \
      --header "${question}" \
      --prompt "› " \
      --prompt.foreground "$C_CORAL_HEX" \
      --header.foreground "$C_NAVY_HEX")
  else
    echo -ne "${C_CORAL}?${C_RESET}  ${question} (caché) "
    read -rs answer
    echo
  fi

  if [[ -z "$answer" ]]; then
    ui_err "Valeur requise pour ${var_name}"
    exit 1
  fi

  printf -v "$var_name" '%s' "$answer"
  # shellcheck disable=SC2163
  export "${var_name?}"
}

ui_input_optional() {
  # ui_input_optional VAR_NAME "Question" [default]
  # Accepte une valeur vide.
  local var_name="$1"
  local question="$2"
  local default="${3:-}"
  local current="${!var_name:-}"

  if [[ -n "$current" ]]; then
    ui_skip "${var_name} déjà défini (${current})"
    return 0
  fi

  local answer=""
  if (( HAS_GUM == 1 )); then
    answer=$(gum input \
      --header "${question}" \
      --placeholder "${default:-(vide)}" \
      --value "${default}" \
      --prompt "› " \
      --prompt.foreground "$C_CORAL_HEX" \
      --header.foreground "$C_NAVY_HEX")
  else
    echo -ne "${C_CORAL}?${C_RESET}  ${question} [${C_DIM}${default:-vide}${C_RESET}] "
    read -r answer
    answer="${answer:-$default}"
  fi

  printf -v "$var_name" '%s' "$answer"
  # shellcheck disable=SC2163
  export "${var_name?}"
}

ui_choose() {
  # ui_choose VAR_NAME "Question" default opt1 opt2 ...
  local var_name="$1"
  local question="$2"
  local default="$3"
  shift 3
  local options=("$@")
  local current="${!var_name:-}"

  if [[ -n "$current" ]]; then
    ui_skip "${var_name} déjà défini (${current})"
    return 0
  fi

  local answer=""
  if (( HAS_GUM == 1 )); then
    answer=$(gum choose \
      --header "${question}" \
      --header.foreground "$C_NAVY_HEX" \
      --cursor.foreground "$C_CORAL_HEX" \
      --selected "${default}" \
      "${options[@]}")
  else
    echo -e "${C_CORAL}?${C_RESET}  ${question}"
    local i=1
    for opt in "${options[@]}"; do
      local marker=" "
      [[ "$opt" == "$default" ]] && marker="*"
      echo "    ${marker} ${i}) ${opt}"
      i=$((i+1))
    done
    echo -ne "  Choix [${default}] › "
    local idx
    read -r idx
    if [[ -z "$idx" ]]; then
      answer="$default"
    elif [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#options[@]} )); then
      answer="${options[$((idx-1))]}"
    else
      answer="$idx"
    fi
  fi

  if [[ -z "$answer" ]]; then
    answer="$default"
  fi

  printf -v "$var_name" '%s' "$answer"
  # shellcheck disable=SC2163
  export "${var_name?}"
}

ui_confirm() {
  # ui_confirm "Question" [default=y]
  local question="$1"
  local default="${2:-y}"

  if (( HAS_GUM == 1 )); then
    if [[ "$default" == "y" ]]; then
      gum confirm \
        --selected.background "$C_NAVY_HEX" \
        --prompt.foreground "$C_NAVY_HEX" \
        "${question}"
    else
      gum confirm \
        --default=false \
        --selected.background "$C_NAVY_HEX" \
        --prompt.foreground "$C_NAVY_HEX" \
        "${question}"
    fi
    return $?
  fi

  local hint="[Y/n]"
  [[ "$default" == "n" ]] && hint="[y/N]"
  echo -ne "${C_CORAL}?${C_RESET}  ${question} ${hint} "
  local answer
  read -r answer
  answer="${answer:-$default}"
  answer=$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')
  [[ "$answer" == "y" || "$answer" == "yes" || "$answer" == "o" || "$answer" == "oui" ]]
}

ui_spin() {
  # ui_spin "Titre" -- cmd args...
  local title="$1"
  shift
  if [[ "${1:-}" == "--" ]]; then shift; fi

  if (( HAS_GUM == 1 )); then
    gum spin \
      --spinner dot \
      --title "${title}" \
      --spinner.foreground "$C_NAVY_HEX" \
      --title.foreground "$C_NAVY_HEX" \
      --show-output \
      -- "$@"
  else
    ui_info "${title}"
    "$@"
  fi
}

# ----- Chemins et constantes ------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly STATE_FILE="${SCRIPT_DIR}/.bootstrap-state"
readonly ENV_FILE="${SCRIPT_DIR}/.bootstrap-env"
readonly PROJECT_NAME="tp-devops-agent-ia"
readonly WORK_DIR="${SCRIPT_DIR}/${PROJECT_NAME}"

# ----- Gestion d'état (idempotence) -----------------------------------------
state_has() {
  [[ -f "$STATE_FILE" ]] && grep -qx "$1" "$STATE_FILE"
}

state_mark() {
  mkdir -p "$(dirname "$STATE_FILE")"
  if ! state_has "$1"; then
    echo "$1" >> "$STATE_FILE"
  fi
}

state_reset() {
  rm -f "$STATE_FILE" "$ENV_FILE"
  ui_ok "État réinitialisé"
}

state_show() {
  local all_steps=(
    "prereqs_checked"
    "credentials_collected"
    "ssh_validated"
    "project_dir_created"
    "microservices_generated"
    "manifests_generated"
    "skills_generated"
    "workflow_generated"
    "sudo_nopasswd_enabled"
    "server_prepared"
    "kubeconfig_fetched"
    "initial_manifests_applied"
    "github_repo_created"
    "github_secrets_set"
    "git_initialized"
    "git_pushed"
    "first_deploy_triggered"
    "deployment_validated"
  )

  echo -e "${C_BOLD}Progression du bootstrap :${C_RESET}"
  for step in "${all_steps[@]}"; do
    if state_has "$step"; then
      echo -e "  ${C_GREEN}✓${C_RESET} ${step}"
    else
      echo -e "  ${C_DIM}○${C_RESET} ${step}"
    fi
  done
}

# ----- Chargement / sauvegarde des credentials ------------------------------
load_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
}

load_config_file() {
  # Charge un fichier VAR=value (mode non-interactif).
  local file="$1"
  if [[ ! -f "$file" ]]; then
    ui_err "Fichier de config introuvable : ${file}"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$file"
  ui_ok "Config chargée depuis ${file}"
}

save_env() {
  cat > "$ENV_FILE" <<EOF
# Généré automatiquement par bootstrap.sh — ne pas versionner
GITHUB_USER="${GITHUB_USER:-}"
GITHUB_REPO_NAME="${GITHUB_REPO_NAME:-}"
DOCKERHUB_USER="${DOCKERHUB_USER:-}"
DOCKERHUB_TOKEN="${DOCKERHUB_TOKEN:-}"
OVH_HOST="${OVH_HOST:-}"
OVH_USER="${OVH_USER:-}"
OVH_SSH_KEY_PATH="${OVH_SSH_KEY_PATH:-}"
APP_AUTHOR="${APP_AUTHOR:-}"
APP_NAME="${APP_NAME:-}"
APP_PORT="${APP_PORT:-}"
API_PORT="${API_PORT:-}"
REPLICAS_API="${REPLICAS_API:-}"
REPLICAS_WEB="${REPLICAS_WEB:-}"
CPU_LIMIT_API="${CPU_LIMIT_API:-}"
MEM_LIMIT_API="${MEM_LIMIT_API:-}"
DEPLOY_ENV="${DEPLOY_ENV:-}"
INGRESS_HOST="${INGRESS_HOST:-}"
EOF
  chmod 600 "$ENV_FILE"
}

# ----- Récap des paramètres -------------------------------------------------
show_summary() {
  local rows=(
    "GitHub        | ${GITHUB_USER}/${GITHUB_REPO_NAME}"
    "Auteur        | ${APP_AUTHOR}"
    "Docker Hub    | ${DOCKERHUB_USER}"
    "Serveur SSH   | ${OVH_USER}@${OVH_HOST}"
    "Clé SSH       | ${OVH_SSH_KEY_PATH}"
    "App name      | ${APP_NAME}"
    "Environnement | ${DEPLOY_ENV}"
    "Port web      | ${APP_PORT}"
    "Port API      | ${API_PORT}"
    "Réplicas API  | ${REPLICAS_API}"
    "Réplicas Web  | ${REPLICAS_WEB}"
    "CPU API       | ${CPU_LIMIT_API}"
    "RAM API       | ${MEM_LIMIT_API}"
    "Ingress host  | ${INGRESS_HOST:-<aucun>}"
  )

  if (( HAS_GUM == 1 )); then
    local content=""
    for row in "${rows[@]}"; do
      content+="${row}"$'\n'
    done
    gum style \
      --border double \
      --border-foreground "$C_NAVY_HEX" \
      --foreground "$C_NAVY_HEX" \
      --padding "1 2" \
      --margin "1 0" \
      --bold \
      "Récapitulatif du bootstrap" \
      "" \
      "${content}"
  else
    echo
    echo -e "${C_NAVY}${C_BOLD}╔═══ Récapitulatif du bootstrap ═══╗${C_RESET}"
    for row in "${rows[@]}"; do
      echo "  ${row}"
    done
    echo -e "${C_NAVY}${C_BOLD}╚═══════════════════════════════════╝${C_RESET}"
    echo
  fi
}

# ----- ÉTAPE 1 : vérification des pré-requis --------------------------------
check_prereqs() {
  ui_step "1/18  Vérification des pré-requis"

  if state_has "prereqs_checked"; then
    ui_skip "Pré-requis déjà validés"
    return 0
  fi

  local required=("git" "gh" "ssh" "ssh-keygen" "curl" "jq")
  local optional=("docker" "claude" "kubectl" "gum")
  local missing=()

  for tool in "${required[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      ui_ok "${tool} présent"
    else
      ui_err "${tool} manquant (requis)"
      missing+=("$tool")
    fi
  done

  for tool in "${optional[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
      ui_ok "${tool} présent"
    else
      ui_warn "${tool} manquant (optionnel mais recommandé)"
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    ui_err "Outils manquants : ${missing[*]}"
    echo
    echo "Installation suggérée :"
    echo "  macOS  : brew install ${missing[*]}"
    echo "  Linux  : sudo apt install ${missing[*]}"
    exit 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    ui_warn "GitHub CLI non authentifié"
    ui_info "Lancement de 'gh auth login'…"
    gh auth login
  fi
  ui_ok "GitHub CLI authentifié"

  state_mark "prereqs_checked"
}

# ----- ÉTAPE 2 : collecte des credentials -----------------------------------
collect_credentials() {
  ui_step "2/18  Collecte des informations du projet"

  if state_has "credentials_collected"; then
    ui_skip "Credentials déjà collectés"
    return 0
  fi

  local gh_default
  gh_default=$(gh api user --jq .login 2>/dev/null || echo "")

  # Bloc 1 — Identités
  ui_input GITHUB_USER       "Ton username GitHub ?" "$gh_default"
  ui_input GITHUB_REPO_NAME  "Nom du dépôt à créer ?" "$PROJECT_NAME"
  ui_input APP_AUTHOR        "Nom de l'auteur (apparaît dans /info) ?" "$GITHUB_USER"
  ui_input DOCKERHUB_USER    "Ton username Docker Hub ?"
  ui_password DOCKERHUB_TOKEN "Ton token Docker Hub (scope Read/Write/Delete)"

  # Bloc 2 — Infra
  ui_input OVH_HOST          "IP/hostname de ton serveur OVH ?"
  ui_input OVH_USER          "Utilisateur SSH sur le serveur ?" "devops"
  ui_input OVH_SSH_KEY_PATH  "Chemin de ta clé SSH privée ?" "$HOME/.ssh/id_ed25519"

  if [[ ! -f "$OVH_SSH_KEY_PATH" ]]; then
    ui_err "Clé SSH introuvable : ${OVH_SSH_KEY_PATH}"
    exit 1
  fi

  # Bloc 3 — Paramètres app
  ui_input APP_NAME      "Nom du déploiement (manifests + images) ?" "tp-app"
  ui_input APP_PORT      "Port HTTP du frontend ?" "80"
  ui_input API_PORT      "Port HTTP de l'API ?" "3000"

  # Bloc 4 — Scaling et resources
  ui_input REPLICAS_API  "Nombre de réplicas API ?" "2"
  ui_input REPLICAS_WEB  "Nombre de réplicas Web ?" "2"
  ui_input CPU_LIMIT_API "Limite CPU API ?" "200m"
  ui_input MEM_LIMIT_API "Limite mémoire API ?" "128Mi"

  # Bloc 5 — Environnement
  ui_choose DEPLOY_ENV       "Environnement cible ?" "dev" "dev" "staging" "prod"
  ui_input_optional INGRESS_HOST "Hostname Ingress (vide = match par IP) ?" ""

  save_env
  ui_ok "Credentials sauvegardés dans ${ENV_FILE} (chmod 600)"
  state_mark "credentials_collected"
}

# ----- Confirmation finale avant exécution ----------------------------------
confirm_summary() {
  # Affiche le récap et demande confirmation. Si non → on relance la collecte.
  while true; do
    show_summary
    if [[ "${BOOTSTRAP_NONINTERACTIVE:-0}" == "1" ]]; then
      ui_ok "Mode non-interactif : exécution sans confirmation"
      return 0
    fi
    if ui_confirm "Lancer le bootstrap avec ces paramètres ?"; then
      return 0
    fi
    ui_warn "Modification des paramètres…"
    # Reset des variables et de l'état "credentials_collected" pour rouvrir le TUI
    GITHUB_USER="" GITHUB_REPO_NAME="" APP_AUTHOR="" DOCKERHUB_USER="" DOCKERHUB_TOKEN=""
    OVH_HOST="" OVH_USER="" OVH_SSH_KEY_PATH=""
    APP_NAME="" APP_PORT="" API_PORT="" REPLICAS_API="" REPLICAS_WEB=""
    CPU_LIMIT_API="" MEM_LIMIT_API="" DEPLOY_ENV="" INGRESS_HOST=""
    # On retire l'étape pour rouvrir la collecte
    if [[ -f "$STATE_FILE" ]]; then
      grep -vx "credentials_collected" "$STATE_FILE" > "${STATE_FILE}.tmp" || true
      mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    collect_credentials
  done
}

# ----- ÉTAPE 3 : validation SSH ---------------------------------------------
validate_ssh() {
  ui_step "3/18  Validation de l'accès SSH au serveur"

  if state_has "ssh_validated"; then
    ui_skip "Accès SSH déjà validé"
    return 0
  fi

  ui_info "Test de connexion à ${OVH_USER}@${OVH_HOST}…"

  if ssh -i "$OVH_SSH_KEY_PATH" \
         -o BatchMode=yes \
         -o ConnectTimeout=10 \
         -o StrictHostKeyChecking=accept-new \
         "${OVH_USER}@${OVH_HOST}" \
         'echo "SSH OK : $(hostname) — $(lsb_release -ds 2>/dev/null || uname -s)"'; then
    ui_ok "Connexion SSH réussie"
  else
    ui_err "Connexion SSH impossible"
    echo "Vérifie que :"
    echo "  - L'IP (${OVH_HOST}) est correcte"
    echo "  - L'utilisateur (${OVH_USER}) existe sur le serveur"
    echo "  - Ta clé publique est dans ~/.ssh/authorized_keys du serveur"
    exit 1
  fi

  state_mark "ssh_validated"
}

# ----- ÉTAPE 4 : création du dossier projet ---------------------------------
create_project_dir() {
  ui_step "4/18  Création du dossier projet"

  if state_has "project_dir_created"; then
    ui_skip "Dossier projet déjà créé : ${WORK_DIR}"
    return 0
  fi

  if [[ -d "$WORK_DIR" ]]; then
    if ui_confirm "${WORK_DIR} existe déjà. Le réutiliser ?"; then
      ui_ok "Réutilisation du dossier existant"
    else
      ui_err "Annulation. Supprime le dossier ou utilise --reset."
      exit 1
    fi
  else
    mkdir -p "$WORK_DIR"
    ui_ok "Dossier créé : ${WORK_DIR}"
  fi

  state_mark "project_dir_created"
}

# ----- ÉTAPE 5 : génération des microservices -------------------------------
# Note : la génération est toujours rejouée (overwrite idempotent). Le state
# tracking ne sert qu'à détecter qu'on a déjà fait une 1re passe pour
# l'affichage du --status. Si APP_NAME / ports changent entre 2 runs, les
# fichiers sont réécrits automatiquement.
generate_microservices() {
  ui_step "5/18  Génération des microservices (API Express + Front nginx)"

  APP_NAME="$APP_NAME" \
  APP_PORT="$APP_PORT" \
  API_PORT="$API_PORT" \
    bash "$SCRIPT_DIR/lib/gen_microservices.sh" "$WORK_DIR" "$APP_AUTHOR"

  ui_ok "Microservices générés"
  state_mark "microservices_generated"
}

# ----- ÉTAPE 6 : génération des manifests K8s -------------------------------
generate_manifests() {
  ui_step "6/18  Génération des manifests Kubernetes"

  APP_NAME="$APP_NAME" \
  APP_PORT="$APP_PORT" \
  API_PORT="$API_PORT" \
  REPLICAS_API="$REPLICAS_API" \
  REPLICAS_WEB="$REPLICAS_WEB" \
  CPU_LIMIT_API="$CPU_LIMIT_API" \
  MEM_LIMIT_API="$MEM_LIMIT_API" \
  INGRESS_HOST="$INGRESS_HOST" \
    bash "$SCRIPT_DIR/lib/gen_manifests.sh" "$WORK_DIR" "$DOCKERHUB_USER"

  ui_ok "Manifests générés (k8s/base/)"
  state_mark "manifests_generated"
}

# ----- ÉTAPE 7 : génération des Skills Claude Code --------------------------
generate_skills() {
  ui_step "7/18  Génération des 4 Skills Claude Code"

  if state_has "skills_generated"; then
    ui_skip "Skills déjà générées"
    return 0
  fi

  bash "$SCRIPT_DIR/lib/gen_skills.sh" "$WORK_DIR"

  ui_ok "Skills générées (.agents/skills/)"
  state_mark "skills_generated"
}

# ----- ÉTAPE 8 : génération du workflow GitHub Actions ----------------------
generate_workflow() {
  ui_step "8/18  Génération du workflow CI/CD GitHub Actions"

  APP_NAME="$APP_NAME" \
    bash "$SCRIPT_DIR/lib/gen_workflow.sh" "$WORK_DIR"

  ui_ok "Workflow généré (.github/workflows/deploy.yml)"
  state_mark "workflow_generated"
}

# ----- ÉTAPE 9 : création du dépôt GitHub -----------------------------------
create_github_repo() {
  ui_step "13/18  Création du dépôt GitHub"

  if state_has "github_repo_created"; then
    ui_skip "Dépôt GitHub déjà créé"
    return 0
  fi

  local repo="${GITHUB_USER}/${GITHUB_REPO_NAME}"

  if gh repo view "$repo" >/dev/null 2>&1; then
    ui_warn "Le dépôt ${repo} existe déjà"
    if ! ui_confirm "Continuer avec ce dépôt existant ?"; then
      ui_err "Annulation"
      exit 1
    fi
  else
    ui_info "Création de ${repo} (public)…"
    gh repo create "$repo" --public \
      --description "TP DevSecOps — chaîne automatisée pilotée par Skills Claude Code" \
      --confirm 2>/dev/null || gh repo create "$repo" --public \
      --description "TP DevSecOps — chaîne automatisée pilotée par Skills Claude Code"
    ui_ok "Dépôt créé : https://github.com/${repo}"
  fi

  state_mark "github_repo_created"
}

# ----- ÉTAPE 10 : configuration des secrets GitHub --------------------------
set_github_secrets() {
  ui_step "14/18  Configuration des secrets GitHub Actions"

  if state_has "github_secrets_set"; then
    ui_skip "Secrets GitHub déjà configurés"
    return 0
  fi

  local repo="${GITHUB_USER}/${GITHUB_REPO_NAME}"

  ui_info "Ajout des secrets dans ${repo}…"

  gh secret set DOCKERHUB_USERNAME --repo "$repo" --body "$DOCKERHUB_USER" && \
    ui_ok "DOCKERHUB_USERNAME"

  gh secret set DOCKERHUB_TOKEN --repo "$repo" --body "$DOCKERHUB_TOKEN" && \
    ui_ok "DOCKERHUB_TOKEN"

  gh secret set OVH_HOST --repo "$repo" --body "$OVH_HOST" && \
    ui_ok "OVH_HOST"

  gh secret set OVH_USER --repo "$repo" --body "$OVH_USER" && \
    ui_ok "OVH_USER"

  gh secret set OVH_SSH_KEY --repo "$repo" < "$OVH_SSH_KEY_PATH" && \
    ui_ok "OVH_SSH_KEY"

  state_mark "github_secrets_set"
}

# ----- ÉTAPE 11 : init Git -----------------------------------------------
init_git() {
  ui_step "15/18  Initialisation Git local"

  if state_has "git_initialized"; then
    ui_skip "Git déjà initialisé"
    return 0
  fi

  cd "$WORK_DIR"

  if [[ ! -d .git ]]; then
    git init -q -b main
    ui_ok "git init (branche main)"
  fi

  cat > .gitignore <<'EOF'
# Bootstrap state (ne jamais versionner les credentials)
.bootstrap-state
.bootstrap-env

# Node
node_modules/
npm-debug.log

# Local kubeconfig
.kube/

# OS
.DS_Store
Thumbs.db

# IDE
.vscode/
.idea/

# Logs
*.log
EOF

  git remote add origin "https://github.com/${GITHUB_USER}/${GITHUB_REPO_NAME}.git" 2>/dev/null || \
    git remote set-url origin "https://github.com/${GITHUB_USER}/${GITHUB_REPO_NAME}.git"

  ui_ok "Remote origin configuré"

  cd - > /dev/null
  state_mark "git_initialized"
}

# ----- ÉTAPE 12 : push initial -----------------------------------------------
push_to_github() {
  ui_step "16/18  Push initial vers GitHub"

  if state_has "git_pushed"; then
    ui_skip "Push initial déjà fait"
    return 0
  fi

  cd "$WORK_DIR"

  git add .
  if git diff --cached --quiet; then
    ui_info "Aucun changement à commiter"
  else
    git -c user.email="${GITHUB_USER}@users.noreply.github.com" \
        -c user.name="${GITHUB_USER}" \
        commit -m "chore: initial bootstrap by bootstrap.sh

- Microservices API (Express) + Web (nginx)
- Manifests Kubernetes (deployments + ingress)
- Skills Claude Code custom (4)
- Pipeline CI/CD GitHub Actions
" -q
    ui_ok "Commit initial créé"
  fi

  ui_info "Push vers origin/main…"
  git push -u origin main
  ui_ok "Push réussi"

  cd - > /dev/null
  state_mark "git_pushed"
}

# ----- ÉTAPE : activation de sudo NOPASSWD ----------------------------------
enable_sudo_nopasswd() {
  ui_step "9/18  Configuration de sudo NOPASSWD pour ${OVH_USER}"

  if state_has "sudo_nopasswd_enabled"; then
    ui_skip "sudo NOPASSWD déjà configuré"
    return 0
  fi

  if ssh -i "$OVH_SSH_KEY_PATH" \
         -o BatchMode=yes \
         "${OVH_USER}@${OVH_HOST}" \
         'sudo -n true' 2>/dev/null; then
    ui_ok "sudo NOPASSWD déjà actif pour ${OVH_USER}"
    state_mark "sudo_nopasswd_enabled"
    return 0
  fi

  ui_warn "L'utilisateur ${OVH_USER} a besoin de sudo NOPASSWD pour les étapes suivantes"
  ui_info "Cette commande va demander une seule fois le mot de passe sudo de ${OVH_USER}"
  ui_info "puis configurera /etc/sudoers.d/ pour les fois suivantes"

  if ! ui_confirm "Configurer sudo NOPASSWD maintenant ?"; then
    ui_err "Sans NOPASSWD, le bootstrap ne peut pas continuer (étapes suivantes en SSH non-interactif)"
    ui_info "Alternative manuelle : sur le serveur, en tant que root :"
    ui_info "  echo \"${OVH_USER} ALL=(ALL) NOPASSWD:ALL\" | sudo tee /etc/sudoers.d/${OVH_USER}"
    ui_info "  sudo chmod 440 /etc/sudoers.d/${OVH_USER}"
    exit 1
  fi

  ui_info "Connexion au serveur (entre ton mot de passe sudo quand demandé)…"

  # shellcheck disable=SC2087
  ssh -t -i "$OVH_SSH_KEY_PATH" \
      "${OVH_USER}@${OVH_HOST}" <<EOF
set -e
echo "${OVH_USER} ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/${OVH_USER}-bootstrap > /dev/null
sudo chmod 440 /etc/sudoers.d/${OVH_USER}-bootstrap
sudo visudo -c -f /etc/sudoers.d/${OVH_USER}-bootstrap || {
  sudo rm -f /etc/sudoers.d/${OVH_USER}-bootstrap
  echo "Erreur de configuration sudoers" >&2
  exit 1
}
echo "OK NOPASSWD configuré dans /etc/sudoers.d/${OVH_USER}-bootstrap"
EOF

  ui_info "Vérification du NOPASSWD…"
  if ssh -i "$OVH_SSH_KEY_PATH" \
         -o BatchMode=yes \
         "${OVH_USER}@${OVH_HOST}" \
         'sudo -n true' 2>/dev/null; then
    ui_ok "sudo NOPASSWD opérationnel"
  else
    ui_err "NOPASSWD configuré mais ne fonctionne pas — vérifier manuellement"
    exit 1
  fi

  state_mark "sudo_nopasswd_enabled"
}

# ----- ÉTAPE 13 : préparation du serveur (k3s + dépendances) ----------------
prepare_server() {
  ui_step "10/18  Préparation du serveur (k3s, kubectl, docker)"

  if state_has "server_prepared"; then
    ui_skip "Serveur déjà préparé"
    return 0
  fi

  ui_info "Vérification de k3s sur le serveur…"

  ssh -i "$OVH_SSH_KEY_PATH" \
      -o StrictHostKeyChecking=accept-new \
      "${OVH_USER}@${OVH_HOST}" \
      'bash -s' < "$SCRIPT_DIR/lib/prepare_server.sh"

  ui_ok "Serveur prêt (k3s opérationnel)"
  state_mark "server_prepared"
}

# ----- ÉTAPE 14 : récupération du kubeconfig --------------------------------
fetch_kubeconfig() {
  ui_step "11/18  Récupération du kubeconfig"

  if state_has "kubeconfig_fetched"; then
    ui_skip "Kubeconfig déjà récupéré"
    return 0
  fi

  local kube_dir="$HOME/.kube"
  local kube_file="${kube_dir}/config-${GITHUB_REPO_NAME}"

  mkdir -p "$kube_dir"

  ui_info "Récupération du kubeconfig depuis le serveur…"

  ssh -i "$OVH_SSH_KEY_PATH" \
      "${OVH_USER}@${OVH_HOST}" \
      "sudo cat /etc/rancher/k3s/k3s.yaml" \
      | sed "s/127.0.0.1/${OVH_HOST}/g" \
      > "$kube_file"

  chmod 600 "$kube_file"

  ui_ok "Kubeconfig sauvegardé : ${kube_file}"
  ui_info "Pour utiliser kubectl localement : export KUBECONFIG=${kube_file}"

  if command -v kubectl >/dev/null 2>&1; then
    if KUBECONFIG="$kube_file" kubectl get nodes >/dev/null 2>&1; then
      ui_ok "kubectl fonctionne depuis ton poste"
    else
      ui_warn "kubectl ne se connecte pas (vérifie le port 6443 du serveur)"
    fi
  fi

  state_mark "kubeconfig_fetched"
}

# ----- ÉTAPE 14b : application initiale des manifests -----------------------
apply_initial_manifests() {
  ui_step "12/18  Application initiale des manifests Kubernetes"

  if state_has "initial_manifests_applied"; then
    ui_skip "Manifests initiaux déjà appliqués"
    return 0
  fi

  ui_info "Copie des manifests sur le serveur…"
  scp -i "$OVH_SSH_KEY_PATH" \
      -o StrictHostKeyChecking=accept-new \
      -r "$WORK_DIR/k8s" \
      "${OVH_USER}@${OVH_HOST}:~/tp-k8s-manifests-initial"

  ui_info "Application des manifests via kubectl…"
  ssh -i "$OVH_SSH_KEY_PATH" \
      "${OVH_USER}@${OVH_HOST}" \
      'export KUBECONFIG=~/.kube/config && kubectl apply -f ~/tp-k8s-manifests-initial/base/'

  ui_ok "Deployments et Ingress créés"
  state_mark "initial_manifests_applied"
}

# ----- ÉTAPE 15 : déclenchement du premier déploiement ----------------------
trigger_first_deploy() {
  ui_step "17/18  Premier déploiement (déclenchement CI/CD)"

  if state_has "first_deploy_triggered"; then
    ui_skip "Premier déploiement déjà déclenché"
    return 0
  fi

  local repo="${GITHUB_USER}/${GITHUB_REPO_NAME}"

  ui_info "Le push précédent a déjà déclenché le workflow."
  ui_info "Suivi en direct : https://github.com/${repo}/actions"

  ui_info "Attente de la fin du workflow (timeout 10 min)…"

  local start_time
  start_time=$(date +%s)
  local max_wait=600

  # Suivi via gum spin si disponible, sinon affichage ligne par ligne.
  if (( HAS_GUM == 1 )); then
    # gum spin attend la fin d'une commande : on en fait une qui poll jusqu'à completed.
    if gum spin \
        --spinner dot \
        --spinner.foreground "$C_NAVY_HEX" \
        --title "Suivi en temps réel du workflow…" \
        --title.foreground "$C_NAVY_HEX" \
        --show-output \
        -- bash -c "
          start_time=${start_time}
          while true; do
            status=\$(gh run list --repo '${repo}' --limit 1 --json status,conclusion --jq '.[0]' 2>/dev/null || echo '{}')
            s=\$(echo \"\$status\" | jq -r '.status // \"unknown\"')
            c=\$(echo \"\$status\" | jq -r '.conclusion // \"\"')
            now=\$(date +%s)
            elapsed=\$((now - start_time))
            echo \"  workflow \$s (\${elapsed}s)\"
            case \"\$s\" in
              completed)
                if [[ \"\$c\" == \"success\" ]]; then exit 0; fi
                echo \"workflow conclusion: \$c\"
                exit 1
                ;;
            esac
            if (( elapsed > ${max_wait} )); then
              echo \"timeout\"
              exit 1
            fi
            sleep 10
          done
        "; then
      ui_ok "Workflow terminé avec succès"
    else
      ui_err "Workflow échoué ou timeout"
      ui_info "Logs : gh run view --repo ${repo} --log"
      exit 1
    fi
  else
    while true; do
      local status
      status=$(gh run list --repo "$repo" --limit 1 --json status,conclusion --jq '.[0]' 2>/dev/null || echo '{}')
      local s c
      s=$(echo "$status" | jq -r '.status // "unknown"')
      c=$(echo "$status" | jq -r '.conclusion // ""')

      case "$s" in
        "completed")
          if [[ "$c" == "success" ]]; then
            ui_ok "Workflow terminé avec succès"
            break
          else
            ui_err "Workflow échoué : ${c}"
            ui_info "Logs : gh run view --repo ${repo} --log"
            exit 1
          fi
          ;;
        "in_progress"|"queued"|"waiting")
          local now elapsed
          now=$(date +%s)
          elapsed=$((now - start_time))
          if (( elapsed > max_wait )); then
            ui_err "Timeout dépassé (10 min)"
            exit 1
          fi
          echo -ne "${C_DIM}   workflow ${s} — ${elapsed}s…${C_RESET}\r"
          sleep 10
          ;;
        *)
          ui_warn "Statut inconnu : ${s}"
          sleep 10
          ;;
      esac
    done
    echo
  fi

  state_mark "first_deploy_triggered"
}

# ----- ÉTAPE 16 : validation finale -----------------------------------------
validate_deployment() {
  ui_step "18/18  Validation du déploiement"

  if state_has "deployment_validated"; then
    ui_skip "Déploiement déjà validé"
    return 0
  fi

  ui_info "Test de l'endpoint /api/health…"

  local url="http://${OVH_HOST}/api/health"
  local response
  local http_code

  for i in {1..10}; do
    if response=$(curl -fsS -m 5 "$url" 2>/dev/null); then
      http_code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
      ui_ok "API répond : ${url} → ${http_code}"
      echo -e "${C_DIM}     ${response}${C_RESET}"
      break
    fi
    ui_info "Tentative ${i}/10… (les pods démarrent)"
    sleep 6
    if (( i == 10 )); then
      ui_err "L'API ne répond pas après 60 s"
      ui_info "Diagnostic : ssh ${OVH_USER}@${OVH_HOST} 'kubectl get pods'"
      exit 1
    fi
  done

  ui_info "Test du frontend…"
  if curl -fsS -m 5 -o /dev/null "http://${OVH_HOST}/"; then
    ui_ok "Frontend répond : http://${OVH_HOST}/"
  else
    ui_warn "Frontend pas encore prêt"
  fi

  state_mark "deployment_validated"
}

# ----- Affichage de succès final --------------------------------------------
print_success() {
  local body
  body=$(cat <<EOF
🌍 Application :  http://${OVH_HOST}
⚙  API :          http://${OVH_HOST}/api/
♡  Health :       http://${OVH_HOST}/api/health
⎇  Dépôt :        https://github.com/${GITHUB_USER}/${GITHUB_REPO_NAME}
⚒  CI/CD :        https://github.com/${GITHUB_USER}/${GITHUB_REPO_NAME}/actions

App         : ${APP_NAME} (${DEPLOY_ENV})
Réplicas    : API=${REPLICAS_API}  Web=${REPLICAS_WEB}
Ressources  : ${CPU_LIMIT_API} CPU / ${MEM_LIMIT_API} RAM (API)

Pour piloter via Claude Code :
  cd ${WORK_DIR}
  claude
  > "Ajoute une route /stats dans l'API, déploie, vérifie la santé"

Pour reset  : ./bootstrap.sh --reset
Pour status : ./bootstrap.sh --status
EOF
)

  if (( HAS_GUM == 1 )); then
    gum style \
      --border double \
      --border-foreground "$C_GREEN_HEX" \
      --foreground "$C_GREEN_HEX" \
      --bold \
      --padding "1 3" \
      --margin "1 0" \
      "OK  BOOTSTRAP TERMINÉ — TOUT EST EN PROD" \
      "" \
      "${body}"
  else
    cat <<EOF

${C_GREEN}${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}
${C_GREEN}${C_BOLD}     OK  BOOTSTRAP TERMINÉ — TOUT EST EN PROD${C_RESET}
${C_GREEN}${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}

${body}
EOF
  fi
}

# ----- Banner d'ouverture ---------------------------------------------------
show_banner() {
  if (( HAS_GUM == 1 )); then
    gum style \
      --border double \
      --border-foreground "$C_NAVY_HEX" \
      --foreground "$C_NAVY_HEX" \
      --bold \
      --padding "1 3" \
      --margin "1 0" \
      --align center \
      --width 70 \
      "TP DevSecOps — Bootstrap automatisé" \
      "" \
      "Création repo + CI/CD + déploiement K8s en un seul script"
  else
    cat <<EOF
${C_NAVY}${C_BOLD}
╔══════════════════════════════════════════════════════════════════════╗
║                                                                      ║
║   TP DevSecOps — Bootstrap automatisé                                ║
║   Création repo + CI/CD + déploiement K8s en un seul script          ║
║                                                                      ║
╚══════════════════════════════════════════════════════════════════════╝
${C_RESET}
EOF
  fi
}

# ----- Args parsing ---------------------------------------------------------
CONFIG_FILE=""
while (( $# > 0 )); do
  case "$1" in
    --reset)
      ensure_gum
      state_reset
      exit 0
      ;;
    --status)
      state_show
      exit 0
      ;;
    --config)
      CONFIG_FILE="${2:?--config requires a file argument}"
      export BOOTSTRAP_NONINTERACTIVE=1
      shift
      ;;
    --help|-h)
      sed -n 's/^# //p; s/^#$//p' "$0" | sed -n '1,/^=*$/p'
      exit 0
      ;;
    *)
      echo "Argument inconnu : $1" >&2
      echo "Usage : $0 [--reset|--status|--config FILE|--help]" >&2
      exit 1
      ;;
  esac
  shift
done

# ----- Orchestration --------------------------------------------------------
ensure_gum
show_banner
load_env
if [[ -n "$CONFIG_FILE" ]]; then
  load_config_file "$CONFIG_FILE"
  save_env
fi
check_prereqs
collect_credentials
confirm_summary
validate_ssh
create_project_dir
generate_microservices
generate_manifests
generate_skills
generate_workflow
enable_sudo_nopasswd
prepare_server
fetch_kubeconfig
apply_initial_manifests
create_github_repo
set_github_secrets
init_git
push_to_github
trigger_first_deploy
validate_deployment
print_success
