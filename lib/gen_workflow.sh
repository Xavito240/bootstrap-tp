#!/usr/bin/env bash
# lib/gen_workflow.sh
# Génère le workflow GitHub Actions CI/CD.
#
# Usage : gen_workflow.sh WORK_DIR
#
# Variables d'environnement :
#   APP_NAME (tp-app) — préfixe des images Docker et noms de deployments
#
# Le workflow utilise le secret DOCKERHUB_USERNAME (configuré côté GitHub),
# pas la valeur locale — c'est pour ça qu'on ne prend pas DOCKERHUB_USER ici.

set -euo pipefail

WORK_DIR="${1:?WORK_DIR required}"
APP_NAME="${APP_NAME:-tp-app}"

API_IMAGE="${APP_NAME}-api"
WEB_IMAGE="${APP_NAME}-web"
API_DEPLOY="${APP_NAME}-api"
WEB_DEPLOY="${APP_NAME}-web"

mkdir -p "$WORK_DIR/.github/workflows"

cat > "$WORK_DIR/.github/workflows/deploy.yml" <<EOF
name: Build & Deploy

on:
  push:
    branches: [main]
  workflow_dispatch:

env:
  DOCKERHUB_USERNAME: \${{ secrets.DOCKERHUB_USERNAME }}
  APP_NAME: ${APP_NAME}

jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      api: \${{ steps.filter.outputs.api }}
      web: \${{ steps.filter.outputs.web }}
      manifests: \${{ steps.filter.outputs.manifests }}
    steps:
      - uses: actions/checkout@v4

      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            api:
              - 'microservices/api/**'
            web:
              - 'microservices/web/**'
            manifests:
              - 'k8s/**'

  build-and-push-api:
    needs: detect-changes
    if: needs.detect-changes.outputs.api == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          username: \${{ secrets.DOCKERHUB_USERNAME }}
          password: \${{ secrets.DOCKERHUB_TOKEN }}
      - uses: docker/build-push-action@v5
        with:
          context: ./microservices/api
          push: true
          cache-from: type=gha,scope=api
          cache-to: type=gha,scope=api,mode=max
          tags: |
            \${{ secrets.DOCKERHUB_USERNAME }}/${API_IMAGE}:latest
            \${{ secrets.DOCKERHUB_USERNAME }}/${API_IMAGE}:\${{ github.sha }}

  build-and-push-web:
    needs: detect-changes
    if: needs.detect-changes.outputs.web == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          username: \${{ secrets.DOCKERHUB_USERNAME }}
          password: \${{ secrets.DOCKERHUB_TOKEN }}
      - uses: docker/build-push-action@v5
        with:
          context: ./microservices/web
          push: true
          cache-from: type=gha,scope=web
          cache-to: type=gha,scope=web,mode=max
          tags: |
            \${{ secrets.DOCKERHUB_USERNAME }}/${WEB_IMAGE}:latest
            \${{ secrets.DOCKERHUB_USERNAME }}/${WEB_IMAGE}:\${{ github.sha }}

  deploy:
    needs: [detect-changes, build-and-push-api, build-and-push-web]
    if: |
      always() &&
      (needs.detect-changes.outputs.api == 'true' ||
       needs.detect-changes.outputs.web == 'true' ||
       needs.detect-changes.outputs.manifests == 'true') &&
      (needs.build-and-push-api.result == 'success' || needs.build-and-push-api.result == 'skipped') &&
      (needs.build-and-push-web.result == 'success' || needs.build-and-push-web.result == 'skipped')
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup SSH
        run: |
          mkdir -p ~/.ssh
          echo "\${{ secrets.OVH_SSH_KEY }}" > ~/.ssh/deploy_key
          chmod 600 ~/.ssh/deploy_key
          ssh-keyscan -H \${{ secrets.OVH_HOST }} >> ~/.ssh/known_hosts

      # On applique TOUJOURS les manifests avant le set-image : idempotent,
      # et ça évite un "deployment not found" quand APP_NAME change.
      # IMPORTANT : on supprime d'abord le dossier cible côté serveur, sinon
      # scp -r créerait un sous-dossier (~/tp-k8s-manifests/k8s/...) au 2e run
      # et kubectl apply -f ~/tp-k8s-manifests/base/ pointerait sur du périmé.
      - name: Apply manifests
        run: |
          ssh -i ~/.ssh/deploy_key \\
            \${{ secrets.OVH_USER }}@\${{ secrets.OVH_HOST }} \\
            'rm -rf ~/tp-k8s-manifests && mkdir -p ~/tp-k8s-manifests'
          scp -i ~/.ssh/deploy_key -r k8s/base \\
            \${{ secrets.OVH_USER }}@\${{ secrets.OVH_HOST }}:~/tp-k8s-manifests/base
          ssh -i ~/.ssh/deploy_key \\
            \${{ secrets.OVH_USER }}@\${{ secrets.OVH_HOST }} \\
            "export KUBECONFIG=~/.kube/config && kubectl apply -f ~/tp-k8s-manifests/base/"

      - name: Deploy API
        if: needs.detect-changes.outputs.api == 'true'
        run: |
          ssh -i ~/.ssh/deploy_key \\
            \${{ secrets.OVH_USER }}@\${{ secrets.OVH_HOST }} \\
            "export KUBECONFIG=~/.kube/config && \\
             kubectl set image deployment/${API_DEPLOY} api=\${{ secrets.DOCKERHUB_USERNAME }}/${API_IMAGE}:\${{ github.sha }} && \\
             kubectl rollout status deployment/${API_DEPLOY} --timeout=2m"

      - name: Deploy Web
        if: needs.detect-changes.outputs.web == 'true'
        run: |
          ssh -i ~/.ssh/deploy_key \\
            \${{ secrets.OVH_USER }}@\${{ secrets.OVH_HOST }} \\
            "export KUBECONFIG=~/.kube/config && \\
             kubectl set image deployment/${WEB_DEPLOY} web=\${{ secrets.DOCKERHUB_USERNAME }}/${WEB_IMAGE}:\${{ github.sha }} && \\
             kubectl rollout status deployment/${WEB_DEPLOY} --timeout=2m"

      - name: Post-deploy health check
        run: |
          for i in {1..15}; do
            if curl -fsS -m 5 "http://\${{ secrets.OVH_HOST }}/api/health" > /tmp/health.json 2>/dev/null; then
              echo "Health check passed"
              cat /tmp/health.json
              exit 0
            fi
            echo "  retry \$i/15…"
            sleep 4
          done
          echo "Health check failed"
          exit 1

      - name: Cleanup SSH
        if: always()
        run: rm -f ~/.ssh/deploy_key
EOF

echo "  - .github/workflows/deploy.yml (images: ${API_IMAGE}/${WEB_IMAGE}, deployments: ${API_DEPLOY}/${WEB_DEPLOY})"
