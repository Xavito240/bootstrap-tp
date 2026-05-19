# Bootstrap TP DevSecOps

> Un seul script pour déployer toute la chaîne, du dépôt GitHub vide au déploiement vérifié en production. TUI interactive (gum), idempotent, paramétrable.

## Ce que fait le script

`bootstrap.sh` enchaîne 18 étapes de manière **idempotente** (relançable sans tout recasser) :

| # | Étape | Action |
|---|---|---|
| 1 | `prereqs_checked` | Vérifie git, gh, ssh, curl, jq, docker, claude, gum |
| 2 | `credentials_collected` | TUI gum pour collecter username GitHub, Docker Hub, IP serveur, clé SSH, paramètres app |
| 3 | `ssh_validated` | Teste la connexion SSH au serveur |
| 4 | `project_dir_created` | Crée le dossier de travail local |
| 5 | `microservices_generated` | Génère API Express + Front nginx + Dockerfiles |
| 6 | `manifests_generated` | Génère manifests K8s (deployments + services + ingress) |
| 7 | `skills_generated` | Génère les 4 Skills Claude Code |
| 8 | `workflow_generated` | Génère `.github/workflows/deploy.yml` |
| 9 | `sudo_nopasswd_enabled` | Configure sudo NOPASSWD sur le serveur |
| 10 | `server_prepared` | SSH : installe Docker, k3s, kubectl, ufw, fail2ban |
| 11 | `kubeconfig_fetched` | Récupère le kubeconfig localement |
| 12 | `initial_manifests_applied` | Applique les manifests sur le cluster (deployments initiaux) |
| 13 | `github_repo_created` | Crée le dépôt GitHub via `gh repo create` |
| 14 | `github_secrets_set` | Configure les secrets (DOCKERHUB, OVH_*) |
| 15 | `git_initialized` | `git init` + remote origin |
| 16 | `git_pushed` | Push initial sur main → déclenche le workflow |
| 17 | `first_deploy_triggered` | Attend la fin du premier workflow (spinner gum) |
| 18 | `deployment_validated` | curl /api/health pour confirmer |

> Note : les étapes de **génération de fichiers** (5, 6, 8) sont rejouées à chaque run pour rester en phase avec `.bootstrap-env` (si tu changes `APP_NAME`, les manifests sont régénérés).

## Utilisation

```bash
# Première exécution (TUI interactive)
./bootstrap.sh

# Mode non-interactif (CI/CD ou reproduction)
./bootstrap.sh --config my-deployment.env

# Voir l'avancement
./bootstrap.sh --status

# Tout effacer et recommencer
./bootstrap.sh --reset
```

### Mode non-interactif : `--config FILE`

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
OVH_SSH_KEY_PATH="/home/user/.ssh/id_ed25519"
APP_NAME="my-app"
APP_PORT="80"
API_PORT="3000"
REPLICAS_API="3"
REPLICAS_WEB="2"
CPU_LIMIT_API="500m"
MEM_LIMIT_API="256Mi"
DEPLOY_ENV="prod"
INGRESS_HOST=""
```

Lance avec :

```bash
./bootstrap.sh --config my-deployment.env
```

Aucune question posée, exécution complète, idéal pour CI/CD ou reproduction de déploiement.

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
| `OVH_SSH_KEY_PATH` | `~/.ssh/id_ed25519` | Chemin clé privée |
| `APP_NAME` | `tp-app` | Préfixe images Docker et noms de deployments |
| `APP_PORT` | `80` | Port HTTP du frontend |
| `API_PORT` | `3000` | Port HTTP de l'API |
| `REPLICAS_API` | `2` | Nombre de réplicas API |
| `REPLICAS_WEB` | `2` | Nombre de réplicas Web |
| `CPU_LIMIT_API` | `200m` | Limite CPU API |
| `MEM_LIMIT_API` | `128Mi` | Limite mémoire API |
| `DEPLOY_ENV` | `dev` | `dev` / `staging` / `prod` (gum choose) |
| `INGRESS_HOST` | (vide) | Hostname Ingress, vide = match par IP |

Tout est sauvegardé dans `.bootstrap-env` (chmod 600).

## Pré-requis sur le poste local

```bash
# macOS
brew install git gh docker jq gum

# Ubuntu/Debian
sudo apt install git gh docker.io jq curl
# gum : https://github.com/charmbracelet/gum#installation

# Claude Code (optionnel mais recommandé)
# voir https://claude.com/code
```

> Si `gum` n'est pas installé, le script propose de l'installer automatiquement (brew/apt). Refus → fallback texte (prompts `read` classiques).

## Pré-requis serveur

- Ubuntu 22.04+ (ou Debian 12+)
- Un utilisateur avec sudo (par défaut `devops`)
- Accès SSH par clé (pas de mot de passe)
- Ports ouverts : 22, 80, 443, 6443

Le serveur est sécurisé automatiquement par le script (ufw + fail2ban).

## Structure du repo bootstrap

```
.
├── bootstrap.sh             # Script principal (orchestration + TUI gum)
├── lib/
│   ├── gen_microservices.sh # Génère API + Web (utilise APP_NAME, APP_PORT, API_PORT)
│   ├── gen_manifests.sh     # Génère manifests K8s (replicas, ressources, ingress host)
│   ├── gen_skills.sh        # Génère les 4 Skills Claude Code
│   ├── gen_workflow.sh      # Génère le workflow GitHub Actions
│   └── prepare_server.sh    # Exécuté via SSH, prépare le serveur
├── .bootstrap-state         # Fichier d'état (généré, ne pas versionner)
├── .bootstrap-env           # Credentials (généré, ne pas versionner, chmod 600)
└── tp-devops-agent-ia/      # Dossier du projet créé par le bootstrap
```

## TUI gum

Le script utilise [gum](https://github.com/charmbracelet/gum) pour l'expérience interactive :

- `gum input` pour les questions (avec placeholder = valeur par défaut)
- `gum input --password` pour le token Docker Hub
- `gum choose` pour `DEPLOY_ENV` (dev / staging / prod)
- `gum confirm` pour les validations Y/n
- `gum style --border` pour le banner, les en-têtes d'étapes, le récap et le succès final
- `gum spin --show-output` pour l'attente du workflow CI

Palette projet : navy `#1E2761`, coral `#F96167`, vert `#2C8B5A`.

### Écran récapitulatif

Avant d'exécuter le bootstrap, un récap de tous les paramètres collectés s'affiche dans un `gum style` encadré. Confirmation `gum confirm` :
- **Oui** → on enchaîne sur la validation SSH puis tout le reste.
- **Non** → la collecte rouvre, tu peux corriger.

## Sécurité

- Les credentials sont stockés dans `.bootstrap-env` avec **chmod 600**
- Ce fichier est ignoré par git (et n'est PAS copié dans le projet généré)
- Les secrets GitHub Actions sont uploadés via `gh secret set` (chiffrés au repos chez GitHub)
- La clé SSH n'est jamais commitée, lue depuis `OVH_SSH_KEY_PATH`
- Le token Docker Hub est saisi via `gum input --password` (jamais affiché à l'écran)
- Le serveur est sécurisé automatiquement (ufw + fail2ban + sudo NOPASSWD ciblé sur l'utilisateur de déploiement)

## Après bootstrap

Une fois le bootstrap terminé, on peut piloter le projet en langage naturel :

```bash
cd tp-devops-agent-ia
claude
> "Ajoute une route /stats dans l'API qui retourne {requests, errors, uptime}, déploie, vérifie"
```

Claude Code détecte automatiquement les 4 skills, les enchaîne, et te ramène un déploiement live en ~3 minutes.

## Dépannage

| Problème | Solution |
|---|---|
| `gh: command not found` | `brew install gh` ou `sudo apt install gh` |
| `gum: command not found` | Le script propose l'install auto ; sinon https://github.com/charmbracelet/gum |
| `${var,,}: bad substitution` | bash 3.2 (macOS) : utiliser `/opt/homebrew/bin/bash` ou installer bash 4+ |
| `Permission denied (publickey)` | Ta clé publique doit être dans `~/.ssh/authorized_keys` du serveur |
| Workflow échoué | `gh run view --log` pour voir les logs détaillés |
| Pods en `ImagePullBackOff` | Vérifier que `DOCKERHUB_TOKEN` a bien les permissions Read/Write/Delete |
| `kubectl: connection refused` | Vérifier que le port 6443 est ouvert dans UFW |
| `deployment X not found` au `set image` | Le step "Apply manifests" du workflow n'a pas tourné ou a échoué — vérifier ses logs |
| Ingress invalide (`host: ...`) | `INGRESS_HOST` dans `.bootstrap-env` contient une valeur invalide — vider et regen (`./bootstrap.sh`) |

## Changer un paramètre après bootstrap

Les paramètres sont chargés depuis `.bootstrap-env` à chaque run. Pour changer `APP_NAME`, `REPLICAS_API`, etc. :

```bash
# 1. Éditer .bootstrap-env
nano .bootstrap-env

# 2. Re-runner — les fichiers de génération sont toujours rejoués
./bootstrap.sh

# 3. Push les nouveaux manifests/workflow
cd tp-devops-agent-ia
git add k8s/ .github/ microservices/
git commit -m "chore: update bootstrap parameters"
git push
```

Le CI réapplique automatiquement les manifests et fait le rolling update.
