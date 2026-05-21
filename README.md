# Bootstrap TP DevSecOps

> Un seul script pour déployer toute la chaîne, du dépôt GitHub vide au déploiement vérifié en production. TUI interactive (gum), idempotent, paramétrable, modulaire.

## Ce que fait le script

`bootstrap.sh` enchaîne **18 étapes idempotentes** : génération du code, provisioning du serveur, création du dépôt GitHub, CI/CD, déploiement K8s et validation HTTP — le tout pilotable depuis un seul terminal.

| # | État | Action |
|---|---|---|
| 1 | `prereqs_checked` | Vérifie git, gh, ssh, curl, jq, docker, kubectl, claude, gum |
| 2 | `credentials_collected` | TUI gum : GitHub, Docker Hub, IP serveur, clé/mdp SSH, app params |
| 3 | `ssh_validated` | Test SSH (clé ou mot de passe via sshpass) |
| 4 | `project_dir_created` | Crée le dossier de travail local |
| 5 | `microservices_generated` | API Express + Front nginx + Dockerfiles |
| 6 | `manifests_generated` | Deployments + Services + Ingress (+ ClusterIssuer si TLS) |
| 7 | `skills_generated` | 5 Skills Claude Code custom |
| 8 | `workflow_generated` | `.github/workflows/deploy.yml` (gitleaks + trivy intégrés) |
| 9 | `sudo_nopasswd_enabled` | Configure sudo NOPASSWD côté serveur |
| 10 | `server_prepared` | Docker, k3s, kubectl, helm, ufw, fail2ban, cert-manager (opt) |
| 11 | `kubeconfig_fetched` | Kubeconfig copié + testé localement |
| 12 | `initial_manifests_applied` | Premier kubectl apply (avant le 1er workflow) |
| 13 | `github_repo_created` | `gh repo create` |
| 14 | `github_secrets_set` | Upload DOCKERHUB_*, OVH_* (clé SSH OU mot de passe) |
| 15 | `git_initialized` | git init + remote origin |
| 16 | `git_pushed` | Push initial → déclenche le workflow |
| 17 | `first_deploy_triggered` | Suit le workflow avec gum spin (timeout 10 min) |
| 18 | `deployment_validated` | curl /api/health + frontend |

> Les étapes 5/6/7/8 sont rejouées à chaque run (overwrite idempotent) pour rester en phase avec `.bootstrap-env`. Le `.bootstrap-state` tracke ce qui est "fait".

## Utilisation

```bash
# Première exécution (TUI interactive)
./bootstrap.sh

# Voir ce qui serait fait sans rien exécuter
./bootstrap.sh --dry-run

# Mode non-interactif (CI/CD ou reproduction)
./bootstrap.sh --config my-deployment.env

# Diagnostic post-déploiement
./bootstrap.sh --doctor          # SSH + cluster + secrets + pods + HTTP
./bootstrap.sh --logs api        # tail logs du pod API (Ctrl-C pour sortir)
./bootstrap.sh --logs web        # idem pour Web
./bootstrap.sh --cluster-info    # nodes/pods/svc/ingress en une vue

# Lancer Claude Code dans le projet
./bootstrap.sh claude            # cd tp-devops-agent-ia/ && exec claude

# Maintenance
./bootstrap.sh --status          # affiche les étapes faites/restantes
./bootstrap.sh --reset           # efface .bootstrap-state + .bootstrap-env
./bootstrap.sh --help            # aide complète
```

## Architecture modulaire

Le script est éclaté en modules réutilisables sous `lib/` :

```
bootstrap.sh                Orchestrateur (PIPELINE déclaratif, ~240 lignes)
lib/
  ui.sh                     gum wrappers + fallback ANSI (ui_prompt, ui_choose, gum_box…)
  state.sh                  state_has / state_mark / state_show piloté par PIPELINE
  config.sh                 ALL_VARS = source unique pour save/load/reset
  ssh_remote.sh             ssh_remote, ssh_remote_tty, scp_remote (clé ou password)
  prereqs.sh                ensure_gum, check_prereqs, ensure_sshpass
  collect.sh                collect_credentials, confirm_summary, show_summary
  runtime.sh                log_init, acquire_lock, trap d'erreur, dry-run
  diag.sh                   cmd_doctor, cmd_logs, cmd_cluster_info
  steps.sh                  Les 16 fonctions step_* exécutées par le pipeline
  gen_microservices.sh      API Express + Front nginx + Dockerfiles
  gen_manifests.sh          Deployments, Services, Ingress, ClusterIssuer TLS
  gen_workflow.sh           Workflow GitHub Actions (gitleaks + trivy)
  gen_skills.sh             Skills Claude Code (5)
  prepare_server.sh         Provisioning serveur (exécuté via SSH)
```

**Ajouter une étape** = ajouter une ligne au tableau `PIPELINE` de `bootstrap.sh` :
```bash
"my_step_id|Mon étape|step_my_function"
```

**Ajouter une variable** = ajouter son nom à `ALL_VARS` dans `lib/config.sh`. Le reste suit (save/load/reset).

## Mode non-interactif : `--config FILE`

Format `VAR=value`, une par ligne :

```bash
# my-deployment.env
GITHUB_USER="myuser"
GITHUB_REPO_NAME="my-app"
APP_AUTHOR="My Name"
DOCKERHUB_USER="myuser"
DOCKERHUB_TOKEN="dckr_pat_..."
OVH_HOST="1.2.3.4"
OVH_USER="devops"
OVH_AUTH_METHOD="key"               # ou "password"
OVH_SSH_KEY_PATH="/home/user/.ssh/id_ed25519"
# OVH_PASSWORD="..."                # si OVH_AUTH_METHOD=password
APP_NAME="my-app"
APP_PORT="80"
API_PORT="3000"
REPLICAS_API="3"
REPLICAS_WEB="2"
CPU_LIMIT_API="500m"
MEM_LIMIT_API="256Mi"
DEPLOY_ENV="prod"
INGRESS_HOST="my-app.example.com"   # hostname public, vide = match par IP
ACME_EMAIL="me@example.com"         # si INGRESS_HOST défini → TLS auto Let's Encrypt
```

```bash
./bootstrap.sh --config my-deployment.env
```

## Paramètres collectés

| Variable | Défaut | Rôle |
|---|---|---|
| `GITHUB_USER` | (auto via `gh`) | Owner du repo GitHub |
| `GITHUB_REPO_NAME` | `tp-devops-agent-ia` | Nom du repo créé |
| `APP_AUTHOR` | = GITHUB_USER | Affiché dans `/info` de l'API |
| `DOCKERHUB_USER` | (requis) | Username Docker Hub |
| `DOCKERHUB_TOKEN` | (requis, masqué) | Token push (scope R/W/D) |
| `OVH_HOST` | (requis) | IP/hostname du serveur cible |
| `OVH_USER` | `devops` | Utilisateur SSH |
| `OVH_AUTH_METHOD` | `key` | `key` (clé SSH) ou `password` (via sshpass) |
| `OVH_SSH_KEY_PATH` | `~/.ssh/id_ed25519` | Chemin clé privée (mode key) |
| `OVH_PASSWORD` | — | Mot de passe SSH (mode password, masqué) |
| `APP_NAME` | `tp-app` | Préfixe images Docker et noms de deployments |
| `APP_PORT` | `80` | Port HTTP du frontend |
| `API_PORT` | `3000` | Port HTTP de l'API |
| `REPLICAS_API` | `2` | Nombre de réplicas API |
| `REPLICAS_WEB` | `2` | Nombre de réplicas Web |
| `CPU_LIMIT_API` | `200m` | Limite CPU API |
| `MEM_LIMIT_API` | `128Mi` | Limite mémoire API |
| `DEPLOY_ENV` | `dev` | `dev` / `staging` / `prod` |
| `INGRESS_HOST` | (vide) | Hostname Ingress, vide = match par IP |
| `ACME_EMAIL` | (vide) | Email Let's Encrypt (TLS auto si défini ET INGRESS_HOST défini) |

Tout est sauvegardé dans `.bootstrap-env` (chmod 600, gitignoré).

## Robustesse

- **Idempotence** via `.bootstrap-state` (relance = reprise propre)
- **Lock file** `.bootstrap.lock` : pas de double exécution accidentelle
- **Trap d'erreur** global : en cas de crash, affiche l'étape, la ligne, la commande, et le chemin du log
- **Logging fichier** `.bootstrap.log` horodaté (auto en mode non-interactif ; opt-in via `BOOTSTRAP_LOG=1` en interactif pour ne pas casser gum)
- **`--dry-run`** : liste les étapes qui seraient exécutées sans rien faire
- **Cache cluster** : `kubeconfig` récupéré + testé une fois, réutilisé

## Sécurité (DevSecOps intégré)

Le workflow CI/CD généré inclut une chaîne de sécurité bloquante :

- **`gitleaks-action@v2`** : scan secrets dans l'arbre Git → bloque le build si fuite détectée
- **`trivy-action@v0.36.0`** : scan vulnérabilités des images Docker (severity HIGH+CRITICAL) → bloque le déploiement
- **`cert-manager`** : provisioning TLS automatique via Let's Encrypt (HTTP-01) si `INGRESS_HOST` + `ACME_EMAIL` sont fournis
- **Serveur** : ufw (deny incoming par défaut) + fail2ban + sudo NOPASSWD ciblé
- **Pods** : `runAsNonRoot`, `runAsUser: 1000`, `allowPrivilegeEscalation: false`, capabilities drop ALL

Côté local :
- `.bootstrap-env` chmod 600, gitignoré
- Token Docker Hub saisi via `gum input --password` (jamais à l'écran)
- Clé SSH validée AVANT upload côté CI (rejet des clés à passphrase qui casseraient le runner)

## Skills Claude Code générées

Le bootstrap génère 5 Skills custom dans `.agents/skills/` du projet :

| Skill | Rôle |
|---|---|
| `microservice-editor` | Modifie le code de l'API (Express) ou du Front (HTML) en suivant les conventions |
| `github-flow` | Commits conventionnels + push sur main |
| `k8s-deploy` | Déploie une nouvelle version via GitOps (bump version → push → CI/CD) |
| `health-monitor` | Vérifie la santé post-deploy, **rollback automatique** si échec |
| `rollback-manager` | Rollback **manuel** ciblé (par revision ou SHA git) |

Après bootstrap :
```bash
./bootstrap.sh claude
> "Ajoute une route /stats à l'API, déploie, vérifie la santé"
```

Claude détecte les Skills, les enchaîne et te ramène un déploiement live en ~3 minutes.

## Pré-requis local

```bash
# macOS
brew install git gh jq gum
# bash 4+ recommandé : brew install bash (le bash 3.2 macOS marche aussi)

# Ubuntu / Debian
sudo apt install git gh jq curl
# gum : https://github.com/charmbracelet/gum#installation

# Optionnels
brew install docker kubectl                # ou apt équivalents
# claude : https://docs.claude.com/claude-code
```

> Si `gum` n'est pas installé, le script propose l'install auto (brew/apt). Refus → fallback texte (prompts `read` classiques).

## Pré-requis serveur

- Ubuntu 22.04+ (ou Debian 12+)
- Un utilisateur avec sudo (par défaut `devops`)
- Accès SSH par **clé OU mot de passe** (le script choisit selon `OVH_AUTH_METHOD`)
- Ports ouverts : 22, 80, 443, 6443 (le script configure ufw automatiquement)

## Variables d'environnement

| Variable | Effet |
|---|---|
| `BOOTSTRAP_NONINTERACTIVE=1` | Active le mode non-interactif (auto si `--config` passé) |
| `BOOTSTRAP_LOG=1` | Force le `.bootstrap.log` même en interactif (TUI gum dégradée) |

## Dépannage

| Problème | Solution |
|---|---|
| `gh: command not found` | `brew install gh` ou `sudo apt install gh` |
| `gum: command not found` | Le script propose l'install auto ; sinon https://github.com/charmbracelet/gum |
| `syntax error near unexpected token '>'` | Tu as lancé via `sh` ; le script se re-exec sous bash automatiquement maintenant |
| `tmp: unbound variable` | (corrigé) bug `trap RETURN` qui leakait — relance simplement |
| `Permission denied (publickey)` | Ta clé publique doit être dans `~/.ssh/authorized_keys` du serveur, ou bascule sur `OVH_AUTH_METHOD=password` |
| Workflow échoué sur gitleaks | Un secret est dans ton historique git, le retirer (`git filter-repo` ou `BFG`) |
| Workflow échoué sur trivy | Image trop vulnérable (HIGH+CRITICAL) ; mettre à jour la base ou relâcher `severity: CRITICAL` dans `lib/gen_workflow.sh` |
| Pods en `ImagePullBackOff` | Token Docker Hub manque la permission Read/Write/Delete |
| `kubectl: connection refused` | Port 6443 fermé ; vérifier ufw côté serveur |
| `deployment X not found` au `set image` | Le step "Apply manifests" du workflow n'a pas tourné, voir ses logs |
| Lock file stale après crash | `rm .bootstrap.lock` puis relance |

## Changer un paramètre après bootstrap

```bash
# 1. Édite .bootstrap-env (ou supprime juste la ligne du paramètre puis relance)
nano .bootstrap-env

# 2. Relance — les étapes "génération" rejouent toujours, les autres skip
./bootstrap.sh

# 3. Push les nouveaux manifests/workflow
cd tp-devops-agent-ia
git add k8s/ .github/ microservices/
git commit -m "chore: update bootstrap parameters"
git push
```

Le CI réapplique automatiquement les manifests et fait le rolling update.

## Licence

MIT (ou adapte selon tes besoins).
