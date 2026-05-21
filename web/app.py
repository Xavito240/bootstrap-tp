#!/usr/bin/env python3
"""
Bootstrap TP DevSecOps — interface web locale.

Sert un formulaire HTML pour collecter les credentials, lance bootstrap.sh
--config en sous-process, et stream les logs en temps réel via SSE.

Démarrage : ./web/start.sh   (ou : python3 app.py)
Bind 127.0.0.1:5005 par défaut (configurable via $PORT).
Aucune authentification — usage strictement local.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import shlex
import signal
import subprocess
import time
from pathlib import Path
from typing import Iterator

from flask import (
    Flask,
    Response,
    jsonify,
    redirect,
    render_template,
    request,
    url_for,
)

# ----- Constantes ----------------------------------------------------------
ROOT = Path(__file__).resolve().parent.parent
BOOTSTRAP_SCRIPT = ROOT / "bootstrap.sh"
ENV_FILE = ROOT / ".bootstrap-env"
STATE_FILE = ROOT / ".bootstrap-state"
LOG_FILE = ROOT / ".bootstrap.log"
LOCK_FILE = ROOT / ".bootstrap.lock"
PID_FILE = ROOT / ".bootstrap.web.pid"

# Liste des variables collectées (miroir de lib/config.sh::ALL_VARS).
# Format : (name, label, kind, default, required, help)
#   kind : "text" | "password" | "select:opt1,opt2" | "number"
FIELDS = [
    # Identités
    ("GITHUB_USER",        "Username GitHub",          "text",     "",                       True,  "Le owner du repo qui sera créé"),
    ("GITHUB_REPO_NAME",   "Nom du repo à créer",      "text",     "tp-devops-agent-ia",     True,  ""),
    ("APP_AUTHOR",         "Nom auteur",               "text",     "",                       True,  "Affiché sur /info de l'API"),
    ("DOCKERHUB_USER",     "Username Docker Hub",      "text",     "",                       True,  ""),
    ("DOCKERHUB_TOKEN",    "Token Docker Hub",         "password", "",                       True,  "Scope Read/Write/Delete — masqué"),
    # Infra
    ("OVH_HOST",           "IP/hostname du serveur",   "text",     "",                       True,  "Ex: 1.2.3.4 ou srv.example.com"),
    ("OVH_USER",           "Utilisateur SSH",          "text",     "devops",                 True,  ""),
    ("OVH_AUTH_METHOD",    "Méthode d'auth SSH",       "select:key,password", "key",         True,  ""),
    ("OVH_SSH_KEY_PATH",   "Chemin clé SSH privée",    "text",     str(Path.home() / ".ssh" / "id_ed25519"), False, "Si auth = key"),
    ("OVH_PASSWORD",       "Mot de passe SSH",         "password", "",                       False, "Si auth = password"),
    # App
    ("APP_NAME",           "Nom du déploiement",       "text",     "tp-app",                 True,  ""),
    ("APP_PORT",           "Port HTTP frontend",       "number",   "80",                     True,  ""),
    ("API_PORT",           "Port HTTP API",            "number",   "3000",                   True,  ""),
    # Scaling
    ("REPLICAS_API",       "Réplicas API",             "number",   "2",                      True,  ""),
    ("REPLICAS_WEB",       "Réplicas Web",             "number",   "2",                      True,  ""),
    ("CPU_LIMIT_API",      "Limite CPU API",           "text",     "200m",                   True,  ""),
    ("MEM_LIMIT_API",      "Limite mémoire API",       "text",     "128Mi",                  True,  ""),
    # Env
    ("DEPLOY_ENV",         "Environnement cible",      "select:dev,staging,prod", "dev",     True,  ""),
    ("INGRESS_HOST",       "Hostname Ingress",         "text",     "",                       False, "Vide = match par IP"),
    ("ACME_EMAIL",         "Email Let's Encrypt",      "text",     "",                       False, "Active TLS auto si défini ET Ingress host défini"),
]

# Mapping id_state → label affichable pour la barre de progression.
# Doit rester en phase avec PIPELINE de bootstrap.sh.
PIPELINE_STEPS = [
    ("prereqs_checked",            "Vérification des pré-requis"),
    ("credentials_collected",      "Collecte des informations"),
    ("ssh_validated",              "Validation SSH"),
    ("project_dir_created",        "Création du dossier projet"),
    ("microservices_generated",    "Génération des microservices"),
    ("manifests_generated",        "Génération des manifests K8s"),
    ("skills_generated",           "Génération des Skills"),
    ("workflow_generated",         "Génération du workflow CI/CD"),
    ("sudo_nopasswd_enabled",      "Configuration sudo NOPASSWD"),
    ("server_prepared",            "Préparation du serveur"),
    ("kubeconfig_fetched",         "Récupération du kubeconfig"),
    ("initial_manifests_applied",  "Application initiale des manifests"),
    ("github_repo_created",        "Création du dépôt GitHub"),
    ("github_secrets_set",         "Configuration des secrets"),
    ("git_initialized",            "Initialisation Git"),
    ("git_pushed",                 "Push initial"),
    ("first_deploy_triggered",     "Premier déploiement (CI/CD)"),
    ("deployment_validated",       "Validation du déploiement"),
]

# ----- App ----------------------------------------------------------------
app = Flask(__name__)
app.config["SECRET_KEY"] = secrets.token_hex(32)

# ----- Helpers ------------------------------------------------------------
def _write_env_file(form: dict) -> None:
    """Écrit .bootstrap-env (chmod 600) à partir du form."""
    lines = ["# Généré par l'interface web — ne pas versionner"]
    for name, *_ in FIELDS:
        value = form.get(name, "").strip()
        # Quote-safe : on échappe les guillemets et antislashs
        value = value.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'{name}="{value}"')
    ENV_FILE.write_text("\n".join(lines) + "\n")
    ENV_FILE.chmod(0o600)


def _read_state() -> list[str]:
    if not STATE_FILE.exists():
        return []
    return [line.strip() for line in STATE_FILE.read_text().splitlines() if line.strip()]


def _bootstrap_running() -> bool:
    if not PID_FILE.exists():
        return False
    try:
        pid = int(PID_FILE.read_text().strip())
        os.kill(pid, 0)
        return True
    except (ValueError, ProcessLookupError, PermissionError):
        PID_FILE.unlink(missing_ok=True)
        return False


def _start_bootstrap() -> int:
    """Lance bootstrap.sh --config .bootstrap-env en background. Renvoie le PID."""
    if _bootstrap_running():
        raise RuntimeError("Un bootstrap est déjà en cours")

    # Stale lock cleanup
    LOCK_FILE.unlink(missing_ok=True)

    # Forcer le logging (le script saura qu'il n'est pas dans un TTY de toute façon)
    env = os.environ.copy()
    env["BOOTSTRAP_NONINTERACTIVE"] = "1"

    # stdout/stderr → .bootstrap.log déjà géré par log_init dans bootstrap.sh
    proc = subprocess.Popen(
        ["bash", str(BOOTSTRAP_SCRIPT), "--config", str(ENV_FILE)],
        cwd=str(ROOT),
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    PID_FILE.write_text(str(proc.pid))
    return proc.pid


def _ansi_strip(s: str) -> str:
    """Retire les codes ANSI pour affichage HTML propre."""
    return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", s)


# ----- Routes -------------------------------------------------------------
@app.route("/")
def index():
    # Pré-remplit avec .bootstrap-env si existe
    prefill = {}
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            m = re.match(r'^([A-Z_][A-Z0-9_]*)="(.*)"$', line)
            if m:
                prefill[m.group(1)] = m.group(2).replace('\\"', '"').replace("\\\\", "\\")
    return render_template(
        "index.html",
        fields=FIELDS,
        prefill=prefill,
        running=_bootstrap_running(),
    )


@app.route("/run", methods=["POST"])
def run():
    # Validation rapide : les required doivent être présents
    missing = []
    auth = request.form.get("OVH_AUTH_METHOD", "key")
    for name, label, kind, default, required, _help in FIELDS:
        if not required:
            continue
        # Skip les champs liés à l'auth non-sélectionnée
        if name == "OVH_SSH_KEY_PATH" and auth != "key":
            continue
        if name == "OVH_PASSWORD" and auth != "password":
            continue
        if not request.form.get(name, "").strip():
            missing.append(label)

    # Le champ d'auth contraint : ssh key OU password requis
    if auth == "key" and not request.form.get("OVH_SSH_KEY_PATH", "").strip():
        missing.append("Chemin clé SSH (auth=key)")
    if auth == "password" and not request.form.get("OVH_PASSWORD", "").strip():
        missing.append("Mot de passe SSH (auth=password)")

    if missing:
        return jsonify({"error": "Champs requis manquants", "missing": missing}), 400

    try:
        _write_env_file(request.form.to_dict())
        pid = _start_bootstrap()
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 409
    except Exception as e:
        return jsonify({"error": f"Échec du lancement : {e}"}), 500

    return jsonify({"status": "started", "pid": pid, "redirect": url_for("progress")})


@app.route("/progress")
def progress():
    return render_template(
        "progress.html",
        steps=PIPELINE_STEPS,
        running=_bootstrap_running(),
    )


@app.route("/state")
def state():
    return jsonify({
        "running": _bootstrap_running(),
        "completed": _read_state(),
        "total": len(PIPELINE_STEPS),
    })


@app.route("/events")
def events() -> Response:
    """Server-Sent Events : stream du .bootstrap.log + état des étapes."""
    def stream() -> Iterator[str]:
        # Position de départ : fin du fichier (on suit la queue)
        last_size = 0
        if LOG_FILE.exists():
            last_size = 0   # on veut TOUT le log, pas juste le nouveau

        last_state: set[str] = set()

        while True:
            # 1) Diff log
            if LOG_FILE.exists():
                size = LOG_FILE.stat().st_size
                if size > last_size:
                    with LOG_FILE.open("r", encoding="utf-8", errors="replace") as f:
                        f.seek(last_size)
                        chunk = f.read()
                    last_size = size
                    for line in chunk.splitlines():
                        data = json.dumps({"type": "log", "line": _ansi_strip(line)})
                        yield f"data: {data}\n\n"

            # 2) Diff state
            current_state = set(_read_state())
            new_steps = current_state - last_state
            for step in new_steps:
                data = json.dumps({"type": "step", "id": step, "done": True})
                yield f"data: {data}\n\n"
            last_state = current_state

            # 3) Fin de run
            if not _bootstrap_running() and LOG_FILE.exists():
                # Quelques cycles de plus pour récupérer les dernières lignes
                time.sleep(1)
                if LOG_FILE.stat().st_size > last_size:
                    continue
                data = json.dumps({"type": "done", "completed": list(current_state)})
                yield f"data: {data}\n\n"
                break

            time.sleep(0.5)

    return Response(stream(), mimetype="text/event-stream", headers={
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",
    })


@app.route("/reset", methods=["POST"])
def reset():
    if _bootstrap_running():
        return jsonify({"error": "Un bootstrap est en cours, impossible de reset"}), 409
    for f in (STATE_FILE, ENV_FILE, LOG_FILE, LOCK_FILE, PID_FILE):
        f.unlink(missing_ok=True)
    return jsonify({"status": "reset"})


@app.route("/stop", methods=["POST"])
def stop():
    if not _bootstrap_running():
        return jsonify({"status": "not_running"})
    try:
        pid = int(PID_FILE.read_text().strip())
        os.killpg(os.getpgid(pid), signal.SIGTERM)
        time.sleep(1)
        if _bootstrap_running():
            os.killpg(os.getpgid(pid), signal.SIGKILL)
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    PID_FILE.unlink(missing_ok=True)
    LOCK_FILE.unlink(missing_ok=True)
    return jsonify({"status": "stopped"})


# ----- Main ---------------------------------------------------------------
if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5005"))
    host = "127.0.0.1"   # JAMAIS exposer ailleurs : la web app n'a pas d'auth
    print(f"\n  Bootstrap TP — interface web")
    print(f"  → http://{host}:{port}\n")
    app.run(host=host, port=port, debug=False, threaded=True)
