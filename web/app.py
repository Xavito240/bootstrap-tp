#!/usr/bin/env python3
"""
Bootstrap TP DevSecOps — interface web locale (multi-workspace).

Permet de gérer plusieurs projets (workspaces) en série :
  - Liste sur /
  - Créer un nouveau workspace
  - Reprendre / éditer / supprimer un workspace existant
  - Lancer bootstrap.sh --workspace <name> et streamer les logs en direct

Bind 127.0.0.1:5005 par défaut. Aucune authentification — usage strictement local.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import signal
import subprocess
import time
from datetime import datetime
from pathlib import Path
from typing import Iterator

from flask import (
    Flask,
    Response,
    abort,
    jsonify,
    redirect,
    render_template,
    request,
    url_for,
)

# ----- Constantes ----------------------------------------------------------
ROOT = Path(__file__).resolve().parent.parent
BOOTSTRAP_SCRIPT = ROOT / "bootstrap.sh"
RUNS_DIR = ROOT / "runs"

# Liste des variables collectées (miroir de lib/config.sh::ALL_VARS).
FIELDS = [
    ("GITHUB_USER",        "Username GitHub",          "text",     "",                       True,  "Le owner du repo qui sera créé"),
    ("GITHUB_REPO_NAME",   "Nom du repo à créer",      "text",     "tp-devops-agent-ia",     True,  ""),
    ("APP_AUTHOR",         "Nom auteur",               "text",     "",                       True,  "Affiché sur /info de l'API"),
    ("DOCKERHUB_USER",     "Username Docker Hub",      "text",     "",                       True,  ""),
    ("DOCKERHUB_TOKEN",    "Token Docker Hub",         "password", "",                       True,  "Scope Read/Write/Delete — masqué"),
    ("OVH_HOST",           "IP/hostname du serveur",   "text",     "",                       True,  "Ex: 1.2.3.4 ou srv.example.com"),
    ("OVH_USER",           "Utilisateur SSH",          "text",     "devops",                 True,  ""),
    ("OVH_AUTH_METHOD",    "Méthode d'auth SSH",       "select:key,password", "key",         True,  ""),
    ("OVH_SSH_KEY_PATH",   "Chemin clé SSH privée",    "text",     str(Path.home() / ".ssh" / "id_ed25519"), False, "Si auth = key"),
    ("OVH_PASSWORD",       "Mot de passe SSH",         "password", "",                       False, "Si auth = password"),
    ("APP_NAME",           "Nom du déploiement",       "text",     "tp-app",                 True,  ""),
    ("APP_PORT",           "Port HTTP frontend",       "number",   "80",                     True,  ""),
    ("API_PORT",           "Port HTTP API",            "number",   "3000",                   True,  ""),
    ("REPLICAS_API",       "Réplicas API",             "number",   "2",                      True,  ""),
    ("REPLICAS_WEB",       "Réplicas Web",             "number",   "2",                      True,  ""),
    ("CPU_LIMIT_API",      "Limite CPU API",           "text",     "200m",                   True,  ""),
    ("MEM_LIMIT_API",      "Limite mémoire API",       "text",     "128Mi",                  True,  ""),
    ("DEPLOY_ENV",         "Environnement cible",      "select:dev,staging,prod", "dev",     True,  ""),
    ("INGRESS_HOST",       "Hostname Ingress",         "text",     "",                       False, "Vide = match par IP"),
    ("ACME_EMAIL",         "Email Let's Encrypt",      "text",     "",                       False, "Active TLS auto si défini ET Ingress host défini"),
]

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

# Regex pour valider un nom de workspace (miroir de _ws_valid_name dans bash).
WS_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,40}$")


# ----- App ----------------------------------------------------------------
app = Flask(__name__)
app.config["SECRET_KEY"] = secrets.token_hex(32)


# ----- Helpers workspace ---------------------------------------------------
class WorkspacePaths:
    def __init__(self, name: str):
        if not WS_NAME_RE.match(name):
            raise ValueError(f"Nom de workspace invalide : {name!r}")
        self.name = name
        self.dir = RUNS_DIR / name
        self.env_file = self.dir / ".bootstrap-env"
        self.state_file = self.dir / ".bootstrap-state"
        self.log_file = self.dir / ".bootstrap.log"
        self.lock_file = self.dir / ".bootstrap.lock"
        self.pid_file = self.dir / ".bootstrap.web.pid"
        self.work_dir = self.dir / "tp-devops-agent-ia"

    def exists(self) -> bool:
        return self.dir.is_dir()

    def ensure_dir(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)

    def completed_steps(self) -> list[str]:
        if not self.state_file.exists():
            return []
        return [
            line.strip()
            for line in self.state_file.read_text().splitlines()
            if line.strip()
        ]

    def is_running(self) -> bool:
        if not self.pid_file.exists():
            return False
        try:
            pid = int(self.pid_file.read_text().strip())
            os.kill(pid, 0)
            return True
        except (ValueError, ProcessLookupError, PermissionError):
            self.pid_file.unlink(missing_ok=True)
            return False

    def prefill(self) -> dict:
        if not self.env_file.exists():
            return {}
        result = {}
        for line in self.env_file.read_text().splitlines():
            m = re.match(r'^([A-Z_][A-Z0-9_]*)="(.*)"$', line)
            if m:
                result[m.group(1)] = (
                    m.group(2).replace('\\"', '"').replace("\\\\", "\\")
                )
        return result

    def last_modified(self) -> str | None:
        if not self.state_file.exists():
            return None
        ts = self.state_file.stat().st_mtime
        return datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M")


def list_workspaces() -> list[dict]:
    if not RUNS_DIR.is_dir():
        return []
    workspaces = []
    for path in sorted(RUNS_DIR.iterdir()):
        if not path.is_dir():
            continue
        try:
            ws = WorkspacePaths(path.name)
        except ValueError:
            continue
        workspaces.append({
            "name": ws.name,
            "completed": len(ws.completed_steps()),
            "total": len(PIPELINE_STEPS),
            "running": ws.is_running(),
            "last_modified": ws.last_modified() or "(jamais)",
        })
    return workspaces


def get_ws(name: str) -> WorkspacePaths:
    try:
        return WorkspacePaths(name)
    except ValueError:
        abort(400, description=f"Nom de workspace invalide : {name}")


def _write_env_file(ws: WorkspacePaths, form: dict) -> None:
    ws.ensure_dir()
    lines = ["# Généré par l'interface web — ne pas versionner"]
    for name, *_ in FIELDS:
        value = form.get(name, "").strip()
        value = value.replace("\\", "\\\\").replace('"', '\\"')
        lines.append(f'{name}="{value}"')
    ws.env_file.write_text("\n".join(lines) + "\n")
    ws.env_file.chmod(0o600)


def _start_bootstrap(ws: WorkspacePaths) -> int:
    if ws.is_running():
        raise RuntimeError("Un bootstrap est déjà en cours sur ce workspace")

    ws.lock_file.unlink(missing_ok=True)

    env = os.environ.copy()
    env["BOOTSTRAP_NONINTERACTIVE"] = "1"

    proc = subprocess.Popen(
        ["bash", str(BOOTSTRAP_SCRIPT),
         "--workspace", ws.name,
         "--config", str(ws.env_file)],
        cwd=str(ROOT),
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    ws.pid_file.write_text(str(proc.pid))
    return proc.pid


def _ansi_strip(s: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", s)


# ----- Routes : index + workspaces ----------------------------------------
@app.route("/")
def index():
    return render_template(
        "index.html",
        workspaces=list_workspaces(),
    )


@app.route("/new", methods=["GET", "POST"])
def new_workspace():
    if request.method == "POST":
        name = request.form.get("workspace_name", "").strip()
        if not WS_NAME_RE.match(name):
            return jsonify({"error": "Nom invalide (a-z, A-Z, 0-9, _, -, max 40)"}), 400
        ws = WorkspacePaths(name)
        if ws.exists():
            return jsonify({"error": f"Workspace '{name}' existe déjà"}), 409
        ws.ensure_dir()
        return jsonify({"redirect": url_for("edit_workspace", name=name)})
    return render_template("new.html")


@app.route("/workspaces/<name>/edit")
def edit_workspace(name):
    ws = get_ws(name)
    if not ws.exists():
        abort(404)
    return render_template(
        "edit.html",
        workspace=name,
        fields=FIELDS,
        prefill=ws.prefill(),
        running=ws.is_running(),
    )


@app.route("/workspaces/<name>/run", methods=["POST"])
def run_workspace(name):
    ws = get_ws(name)
    if not ws.exists():
        abort(404)

    missing = []
    auth = request.form.get("OVH_AUTH_METHOD", "key")
    for field_name, label, kind, default, required, _help in FIELDS:
        if not required:
            continue
        if field_name == "OVH_SSH_KEY_PATH" and auth != "key":
            continue
        if field_name == "OVH_PASSWORD" and auth != "password":
            continue
        if not request.form.get(field_name, "").strip():
            missing.append(label)

    if auth == "key" and not request.form.get("OVH_SSH_KEY_PATH", "").strip():
        missing.append("Chemin clé SSH (auth=key)")
    if auth == "password" and not request.form.get("OVH_PASSWORD", "").strip():
        missing.append("Mot de passe SSH (auth=password)")

    if missing:
        return jsonify({"error": "Champs requis manquants", "missing": missing}), 400

    try:
        _write_env_file(ws, request.form.to_dict())
        _start_bootstrap(ws)
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 409
    except Exception as e:
        return jsonify({"error": f"Échec du lancement : {e}"}), 500

    return jsonify({
        "status": "started",
        "redirect": url_for("progress_workspace", name=name),
    })


@app.route("/workspaces/<name>/progress")
def progress_workspace(name):
    ws = get_ws(name)
    if not ws.exists():
        abort(404)
    return render_template(
        "progress.html",
        workspace=name,
        steps=PIPELINE_STEPS,
        running=ws.is_running(),
    )


@app.route("/workspaces/<name>/state")
def state_workspace(name):
    ws = get_ws(name)
    if not ws.exists():
        abort(404)
    return jsonify({
        "running": ws.is_running(),
        "completed": ws.completed_steps(),
        "total": len(PIPELINE_STEPS),
    })


@app.route("/workspaces/<name>/events")
def events_workspace(name) -> Response:
    ws = get_ws(name)
    if not ws.exists():
        abort(404)

    def stream() -> Iterator[str]:
        last_size = 0
        last_state: set[str] = set()

        while True:
            if ws.log_file.exists():
                size = ws.log_file.stat().st_size
                if size > last_size:
                    with ws.log_file.open("r", encoding="utf-8", errors="replace") as f:
                        f.seek(last_size)
                        chunk = f.read()
                    last_size = size
                    for line in chunk.splitlines():
                        data = json.dumps({"type": "log", "line": _ansi_strip(line)})
                        yield f"data: {data}\n\n"

            current_state = set(ws.completed_steps())
            new_steps = current_state - last_state
            for step in new_steps:
                data = json.dumps({"type": "step", "id": step, "done": True})
                yield f"data: {data}\n\n"
            last_state = current_state

            if not ws.is_running() and ws.log_file.exists():
                time.sleep(1)
                if ws.log_file.stat().st_size > last_size:
                    continue
                data = json.dumps({"type": "done", "completed": list(current_state)})
                yield f"data: {data}\n\n"
                break

            time.sleep(0.5)

    return Response(stream(), mimetype="text/event-stream", headers={
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",
    })


@app.route("/workspaces/<name>/reset", methods=["POST"])
def reset_workspace(name):
    ws = get_ws(name)
    if not ws.exists():
        abort(404)
    if ws.is_running():
        return jsonify({"error": "Un bootstrap est en cours"}), 409
    for f in (ws.state_file, ws.env_file, ws.log_file, ws.lock_file, ws.pid_file):
        f.unlink(missing_ok=True)
    return jsonify({"status": "reset"})


@app.route("/workspaces/<name>/delete", methods=["POST"])
def delete_workspace(name):
    ws = get_ws(name)
    if not ws.exists():
        abort(404)
    if ws.is_running():
        return jsonify({"error": "Un bootstrap est en cours, impossible de supprimer"}), 409
    if name == "default":
        return jsonify({"error": "Refus de supprimer le workspace 'default' (--reset à la place)"}), 400

    import shutil
    shutil.rmtree(ws.dir)
    return jsonify({"status": "deleted"})


@app.route("/workspaces/<name>/stop", methods=["POST"])
def stop_workspace(name):
    ws = get_ws(name)
    if not ws.exists():
        abort(404)
    if not ws.is_running():
        return jsonify({"status": "not_running"})
    try:
        pid = int(ws.pid_file.read_text().strip())
        os.killpg(os.getpgid(pid), signal.SIGTERM)
        time.sleep(1)
        if ws.is_running():
            os.killpg(os.getpgid(pid), signal.SIGKILL)
    except Exception as e:
        return jsonify({"error": str(e)}), 500
    ws.pid_file.unlink(missing_ok=True)
    ws.lock_file.unlink(missing_ok=True)
    return jsonify({"status": "stopped"})


# ----- Main ---------------------------------------------------------------
if __name__ == "__main__":
    port = int(os.environ.get("PORT", "5005"))
    host = "127.0.0.1"
    print(f"\n  Bootstrap TP — interface web (multi-workspace)")
    print(f"  → http://{host}:{port}\n")
    app.run(host=host, port=port, debug=False, threaded=True)
