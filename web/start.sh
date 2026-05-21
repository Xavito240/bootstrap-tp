#!/usr/bin/env bash
# web/start.sh — Lance l'interface web locale du bootstrap.
#
# Pour les utilisateurs non-tech :
#   ./web/start.sh
# Et voilà : un navigateur s'ouvre sur le formulaire.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="${SCRIPT_DIR}/venv"
PORT="${PORT:-5005}"

cd "$SCRIPT_DIR"

# ----- 1. Python 3 dispo ? --------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "✗ Python 3 introuvable."
  echo "  macOS  : brew install python3"
  echo "  Linux  : sudo apt install python3 python3-venv"
  exit 1
fi

# ----- 2. Venv + dépendances ------------------------------------------------
if [[ ! -d "$VENV" ]]; then
  echo "→ Création de l'environnement Python (1ère exécution)…"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet -r requirements.txt
  echo "✓ Environnement prêt"
fi

# ----- 3. Vérif bootstrap.sh ------------------------------------------------
if [[ ! -x "$SCRIPT_DIR/../bootstrap.sh" ]]; then
  echo "✗ bootstrap.sh introuvable ou non exécutable dans le dossier parent"
  exit 1
fi

# ----- 4. Ouvre le navigateur en arrière-plan ------------------------------
URL="http://127.0.0.1:${PORT}"
(
  sleep 1.5
  if command -v open >/dev/null 2>&1; then         # macOS
    open "$URL"
  elif command -v xdg-open >/dev/null 2>&1; then   # Linux
    xdg-open "$URL"
  fi
) &

# ----- 5. Lance Flask -------------------------------------------------------
echo
echo "═══════════════════════════════════════════════════════════════════"
echo "  Bootstrap TP DevSecOps — interface web"
echo "═══════════════════════════════════════════════════════════════════"
echo
echo "  → ${URL}"
echo
echo "  Ctrl-C pour arrêter"
echo
echo "═══════════════════════════════════════════════════════════════════"
echo

PORT="$PORT" exec "$VENV/bin/python3" app.py
