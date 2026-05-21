# Bootstrap TP DevSecOps

> Déploie une chaîne DevSecOps complète (microservices + Kubernetes + CI/CD + Skills Claude Code) en un clic — interface web ou CLI au choix. Idempotent, paramétrable, modulaire.

[![bash](https://img.shields.io/badge/bash-4%2B-blue.svg)](#)
[![python](https://img.shields.io/badge/python-3.9%2B-blue.svg)](#)
[![license](https://img.shields.io/badge/license-MIT-green.svg)](#licence)

---

## Table des matières

- [Démarrage rapide](#démarrage-rapide)
- [Interface web (recommandée)](#interface-web-recommandée)
- [CLI (pour habitués du terminal)](#cli-pour-habitués-du-terminal)
- [Ce que fait le script](#ce-que-fait-le-script)
- [Architecture modulaire](#architecture-modulaire)
- [Paramètres collectés](#paramètres-collectés)
- [Sécurité (DevSecOps intégré)](#sécurité-devsecops-intégré)
- [Robustesse](#robustesse)
- [Skills Claude Code générées](#skills-claude-code-générées)
- [Pré-requis](#pré-requis)
- [Mode non-interactif (CI/CD)](#mode-non-interactif-cicd)
- [Dépannage](#dépannage)
- [Licence](#licence)

---

## Démarrage rapide

```bash
git clone https://github.com/Xavito240/bootstrap-tp.git
cd bootstrap-tp

# Option A — Interface web (le plus simple)
./web/start.sh

# Option B — CLI
./bootstrap.sh
```

> 💡 Si tu n'es pas à l'aise avec le terminal : **prends l'option A**. Tu n'auras besoin que de ton navigateur après le `./web/start.sh`.

---

## Interface web (recommandée)

```bash
./web/start.sh
```

Un navigateur s'ouvre automatiquement sur `http://127.0.0.1:5005` avec un formulaire. Remplis, clique, regarde les logs en direct.

### Ce que tu obtiens

| Écran | Description |
|---|---|
| **Formulaire** | 5 sections (Identités, Serveur, App, Scaling, Env+TLS). Auth SSH conditionnelle (clé OU mot de passe). Validation côté serveur avec liste claire des champs manquants. |
| **Progression** | 18 étapes affichées à gauche (cercles vides → coral pulsant → ✓ vert). Logs en direct à droite via Server-Sent Events. Auto-scroll, ANSI codes nettoyés. |
| **Succès** | Modal avec les liens extraits du log : application live, dépôt GitHub, page CI/CD, endpoint /api/health. |

### Fonctionnalités clés

- **Pré-remplissage automatique** depuis `.bootstrap-env` si le fichier existe (utile pour relancer après modification)
- **Bouton Reset** : nettoie l'état + credentials (avec confirmation)
- **Bouton Arrêter** : envoie `SIGTERM` au bootstrap en cours, puis `SIGKILL` si refus
- **Détection de stale lock** : si le serveur a planté précédemment, le lock file est ignoré au prochain démarrage
- **Aide sudo NOPASSWD intégrée** : un toggle affiche les 2 commandes à coller sur ton serveur, pré-remplies avec ton username SSH

### Sécurité de l'interface

- **Bind 127.0.0.1 uniquement** — impossible d'y accéder depuis le réseau
- Aucune authentification (inutile pour un usage local solo)
- Champs sensibles en `<input type="password">` (masqués à l'écran)
- Credentials écrits dans `.bootstrap-env` avec **chmod 600** (jamais en transit réseau)
- Aucun fichier sensible ne quitte ta machine

### Comment ça marche sous le capot

```
[Browser]  ──form HTML──▶  [Flask local 127.0.0.1:5005]
   │                              │
   │                              ├─▶ écrit .bootstrap-env (chmod 600)
   │                              ├─▶ subprocess: bash bootstrap.sh --config ...
   │                              │      │
   │                              │      └─▶ écrit .bootstrap.log + .bootstrap-state
   │                              │
   ◀────SSE stream────────────────┤   tail .bootstrap.log
                                  │   diff .bootstrap-state
                                  ▼
                               18 étapes ✓
```

Stack : Flask (Python 3, ~280 lignes) + HTML/CSS/JS vanilla + SSE (Server-Sent Events). Aucun WebSocket, aucun framework JS, aucune base de données.

---

## CLI (pour habitués du terminal)

```bash
# Première exécution (TUI interactive gum)
./bootstrap.sh

# Voir ce qui serait fait sans rien exécuter
./bootstrap.sh --dry-run

# Mode non-interactif (CI/CD ou reproduction de déploiement)
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

Le CLI utilise [gum](https://github.com/charmbracelet/gum) pour une TUI agréable (prompts, menus, spinners, encadrés). Si `gum` n'est pas installé, le script propose l'install automatique. Refus → fallback texte avec `read` classique.

---

## Ce que fait le script

`bootstrap.sh` enchaîne **18 étapes idempotentes** : génération du code, provisioning du serveur, création du dépôt GitHub, CI/CD, déploiement K8s et validation HTTP. Que tu lances depuis l'UI web ou la CLI, c'est le même pipeline.

| # | ID d'état | Action |
|---|---|---|
| 1 | `prereqs_checked` | Vérifie git, gh, ssh, curl, jq, docker, kubectl, claude, gum |
| 2 | `credentials_collected` | Collecte des paramètres (TUI gum **ou** formulaire web) |
| 3 | `ssh_validated` | Test SSH (clé ou mot de passe via sshpass) |
| 4 | `project_dir_created` | Crée le dossier de travail local |
| 5 | `microservices_generated` | API Express + Front nginx + Dockerfiles |
| 6 | `manifests_generated` | Deployments + Services + Ingress (+ ClusterIssuer si TLS) |
| 7 | `skills_generated` | 5 Skills Claude Code custom |
| 8 | `workflow_generated` | `.github/workflows/deploy.yml` (gitleaks + trivy intégrés) |
| 9 | `sudo_nopasswd_enabled` | Configure sudo NOPASSWD côté serveur |
| 10 | `server_prepared` | Docker, k3s, kubectl, helm, ufw, fail2ban, cert-manager (opt.) |
| 11 | `kubeconfig_fetched` | Kubeconfig copié + testé localement |
| 12 | `initial_manifests_applied` | Premier kubectl apply (avant le 1er workflow CI) |
| 13 | `github_repo_created` | `gh repo create` |
| 14 | `github_secrets_set` | Upload DOCKERHUB_*, OVH_* (clé SSH OU mot de passe) |
| 15 | `git_initialized` | git init + remote origin |
| 16 | `git_pushed` | Push initial → déclenche le workflow |
| 17 | `first_deploy_triggered` | Suit le workflow avec gum spin (timeout 10 min) |
| 18 | `deployment_validated` | curl /api/health + frontend |

> Les étapes 5/6/7/8 sont rejouées à chaque run (overwrite idempotent) pour rester en phase avec `.bootstrap-env`. Le `.bootstrap-state` tracke ce qui est "fait" pour les autres.

---

## Architecture modulaire

```
bootstrap-tp/
├── bootstrap.sh              Orchestrateur CLI (PIPELINE déclaratif, ~240 lignes)
├── lib/                      Modules réutilisables
│   ├── ui.sh                   gum wrappers + fallback ANSI
│   ├── state.sh                state_has/mark/show piloté par PIPELINE
│   ├── config.sh               ALL_VARS = source unique pour save/load/reset
│   ├── ssh_remote.sh           ssh_remote, ssh_remote_tty, scp_remote
│   ├── prereqs.sh              ensure_gum, check_prereqs, ensure_sshpass
│   ├── collect.sh              collect_credentials, confirm_summary
│   ├── runtime.sh              log_init, acquire_lock, trap d'erreur
│   ├── diag.sh                 cmd_doctor, cmd_logs, cmd_cluster_info
│   ├── steps.sh                Fonctions step_* exécutées par le pipeline
│   ├── gen_microservices.sh    API Express + Front nginx + Dockerfiles
│   ├── gen_manifests.sh        Deployments, Services, Ingress, ClusterIssuer TLS
│   ├── gen_workflow.sh         Workflow GitHub Actions (gitleaks + trivy)
│   ├── gen_skills.sh           Skills Claude Code (5)
│   └── prepare_server.sh       Provisioning serveur (exécuté via SSH)
├── web/                      Interface web (Flask + SSE)
│   ├── app.py                  Backend Flask (~280 lignes)
│   ├── templates/              index.html (form) + progress.html (live)
│   ├── static/                 style.css + app.js + progress.js
│   ├── requirements.txt        Flask uniquement
│   └── start.sh                Launcher venv + browser auto
├── tp-devops-agent-ia/       Projet généré (créé par le bootstrap)
├── .bootstrap-state          État local (gitignoré)
├── .bootstrap-env            Credentials chmod 600 (gitignoré)
├── .bootstrap.log            Trace horodatée (gitignoré)
└── README.md
```

### Étendre le script

**Ajouter une étape** : une seule ligne au tableau `PIPELINE` de `bootstrap.sh` :
```bash
"my_step_id|Mon étape|step_my_function"
```

**Ajouter une variable** : une seule ligne à `ALL_VARS` dans `lib/config.sh`. Le reste suit (save/load/reset/form web).

---

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
| `ACME_EMAIL` | (vide) | Email Let's Encrypt (TLS auto si défini ET `INGRESS_HOST` défini) |

Tout est sauvegardé dans `.bootstrap-env` (chmod 600, gitignoré).

---

## Sécurité (DevSecOps intégré)

Le workflow CI/CD généré inclut une chaîne de sécurité **bloquante** :

| Étape | Outil | Effet |
|---|---|---|
| Scan secrets | `gitleaks-action@v2` | Bloque le build si un secret est leaké dans git |
| Scan image API | `trivy-action@v0.36.0` | Bloque le deploy sur vulns HIGH/CRITICAL |
| Scan image Web | `trivy-action@v0.36.0` | Idem pour le frontend |
| TLS auto | `cert-manager` + Let's Encrypt | Provisioning HTTPS (HTTP-01) si `INGRESS_HOST` + `ACME_EMAIL` |

Le serveur déployé est aussi sécurisé automatiquement :
- **ufw** : deny incoming par défaut, n'autorise que 22, 80, 443, 6443
- **fail2ban** : protection brute-force SSH
- **sudo NOPASSWD** ciblé sur l'utilisateur de déploiement (pas un blanc-seing root)

Les pods utilisent un security context strict :
- `runAsNonRoot: true`, `runAsUser: 1000`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`

Côté local :
- `.bootstrap-env` chmod 600, jamais committé
- Token Docker Hub masqué à la saisie (CLI + Web)
- Clé SSH validée AVANT upload côté CI (rejet des clés à passphrase qui casseraient le runner)

---

## Robustesse

- **Idempotence** via `.bootstrap-state` (relance = reprise propre)
- **Lock file** `.bootstrap.lock` : empêche deux exécutions simultanées (détecte les stale locks via PID)
- **Trap d'erreur global** : en cas de crash, affiche l'étape en cours, la ligne, la commande, et le chemin du log
- **Logging fichier** `.bootstrap.log` horodaté (auto en mode non-interactif / Web UI ; opt-in via `BOOTSTRAP_LOG=1` en CLI interactif)
- **`--dry-run`** : liste les étapes qui seraient exécutées sans rien faire
- **Reprise après crash** : il suffit de relancer `./bootstrap.sh` (ou `./web/start.sh`), les étapes déjà ✓ sont skip
- **Re-exec automatique sous bash** : si lancé via `sh` ou `bash --posix`, le script se relance proprement

---

## Skills Claude Code générées

Le bootstrap génère **5 Skills custom** dans `.agents/skills/` du projet généré :

| Skill | Rôle |
|---|---|
| `microservice-editor` | Modifie le code de l'API (Express) ou du Front (HTML) en suivant les conventions |
| `github-flow` | Commits conventionnels + push sur main |
| `k8s-deploy` | Déploie une nouvelle version via GitOps (bump version → push → CI/CD) |
| `health-monitor` | Vérifie la santé post-deploy, **rollback automatique** si échec |
| `rollback-manager` | Rollback **manuel** ciblé (par revision number ou SHA git) |

Après bootstrap :
```bash
./bootstrap.sh claude
> "Ajoute une route /stats à l'API, déploie, vérifie la santé"
```

Claude détecte les Skills, les enchaîne, et te ramène un déploiement live en ~3 minutes.

---

## Pré-requis

### Pour la Web UI (le plus simple)

- **Python 3.9+** (le `start.sh` crée un venv et installe Flask tout seul)
- Un navigateur

```bash
# macOS
python3 --version    # devrait sortir 3.9 ou plus

# Ubuntu / Debian
sudo apt install python3 python3-venv
```

### Pour la CLI

```bash
# macOS
brew install git gh jq gum
# bash 4+ recommandé : brew install bash (le bash 3.2 macOS marche aussi)

# Ubuntu / Debian
sudo apt install git gh jq curl
# gum : https://github.com/charmbracelet/gum#installation
```

> Si `gum` n'est pas installé, le CLI propose l'install auto (brew/apt). Refus → fallback texte (prompts `read` classiques).

### Optionnels (CLI + Web)

```bash
brew install docker kubectl       # ou apt équivalents
# claude : https://docs.claude.com/claude-code
```

### Serveur cible

- Ubuntu 22.04+ (ou Debian 12+)
- Un utilisateur avec sudo (par défaut `devops`)
- Accès SSH par **clé OU mot de passe** (le script choisit selon `OVH_AUTH_METHOD`)
- **`sudo NOPASSWD` configuré** pour l'utilisateur SSH (le script propose la commande à coller si manquant)
- Ports ouverts : 22, 80, 443, 6443 (le script configure ufw automatiquement)

---

## Mode non-interactif (CI/CD)

Pour reproduire un déploiement en CI/CD ou scripter :

```bash
./bootstrap.sh --config my-deployment.env
```

Format `VAR=value` du fichier `.env` :

```bash
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
ACME_EMAIL="me@example.com"         # active TLS auto si INGRESS_HOST défini
```

### Variables d'environnement utiles

| Variable | Effet |
|---|---|
| `BOOTSTRAP_NONINTERACTIVE=1` | Active le mode non-interactif (auto si `--config` passé) |
| `BOOTSTRAP_LOG=1` | Force le `.bootstrap.log` même en CLI interactif (TUI gum dégradée) |
| `PORT=8080 ./web/start.sh` | Change le port d'écoute de l'interface web (défaut : 5005) |

---

## Dépannage

| Problème | Solution |
|---|---|
| **CLI** : `gh: command not found` | `brew install gh` ou `sudo apt install gh` |
| **CLI** : `gum: command not found` | Le script propose l'install auto ; sinon https://github.com/charmbracelet/gum |
| **CLI** : `syntax error near unexpected token '>'` | Tu as lancé via `sh` ; le script se re-exec sous bash automatiquement maintenant |
| **CLI** : `tmp: unbound variable` | (corrigé) bug `trap RETURN` qui leakait — relance simplement |
| **Web** : `python3: command not found` | Installe Python 3 : `brew install python3` ou `sudo apt install python3 python3-venv` |
| **Web** : port 5005 déjà utilisé | `PORT=8080 ./web/start.sh` (ou tout autre port libre) |
| **Web** : page blanche / SSE déconnecté | Recharge la page ; le client `EventSource` resync via `/state` |
| SSH : `Permission denied (publickey)` | Ta clé publique doit être dans `~/.ssh/authorized_keys` du serveur, ou bascule sur `OVH_AUTH_METHOD=password` |
| Workflow échoué sur gitleaks | Un secret est dans ton historique git, le retirer (`git filter-repo` ou `BFG`) |
| Workflow échoué sur trivy | Image trop vulnérable (HIGH+CRITICAL) ; mettre à jour la base ou relâcher `severity: CRITICAL` dans `lib/gen_workflow.sh` |
| Pods en `ImagePullBackOff` | Token Docker Hub manque la permission Read/Write/Delete |
| `kubectl: connection refused` | Port 6443 fermé ; vérifier ufw côté serveur |
| `deployment X not found` au `set image` | Le step "Apply manifests" du workflow n'a pas tourné, voir ses logs |
| Lock file stale après crash | `rm .bootstrap.lock` puis relance |

### Changer un paramètre après bootstrap

```bash
# Option A — via Web UI : relance start.sh, modifie le formulaire (pré-rempli)
./web/start.sh

# Option B — via CLI
nano .bootstrap-env              # édite manuellement
./bootstrap.sh                   # les étapes "génération" rejouent toujours

# Puis push les nouveaux manifests/workflow
cd tp-devops-agent-ia
git add k8s/ .github/ microservices/
git commit -m "chore: update bootstrap parameters"
git push
```

Le CI réapplique automatiquement les manifests et fait le rolling update.

---

## Licence

MIT.

---

<sub>Bootstrap TP DevSecOps — chaîne IA-pilotée avec Claude Code.</sub>
