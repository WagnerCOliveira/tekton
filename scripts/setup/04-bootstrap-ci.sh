#!/usr/bin/env bash
# Monta o namespace `ci` inteiro do zero: namespace, cluster resolver, RBAC do
# EventListener, secret do webhook, Pipelines por stack, Triggers e EventListener.
# Consolida o playbook "Montar o ci do zero" (docs/04-ci-operacional.md §4).
#
# Pré-requisitos: kubectl configurado; manifestos em yaml/ci/.
# Idempotente: seguro reaplicar.
#
# Uso: ./04-bootstrap-ci.sh [--help]

set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Uso: $0"
  echo "Cria o namespace ci, habilita cluster resolver, aplica RBAC, cria o secret"
  echo "do webhook (se ainda não existir), aplica Pipelines e Triggers, e aguarda"
  echo "o EventListener ficar Ready."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
YAML_CI="$REPO_ROOT/yaml/ci"

echo "== Passo 1 — namespace ci =="
kubectl create ns ci --dry-run=client -o yaml | kubectl apply -f -
kubectl label ns ci tekton.dev/role=platform --overwrite

echo "== Passo 2 — cluster resolver =="
kubectl -n tekton-pipelines patch cm feature-flags \
  --type merge -p '{"data":{"enable-cluster-resolver":"true"}}'
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-resolver-config
  namespace: tekton-pipelines-resolvers
data:
  default-namespace: "ci"
  allowed-namespaces: "ci"
EOF

echo "== Passo 3 — RBAC do EventListener =="
kubectl apply -f "$YAML_CI/rbac.yaml"

echo "== Passo 4 — secret do webhook (só cria se não existir) =="
if kubectl -n ci get secret gitlab-webhook-secret >/dev/null 2>&1; then
  echo "  secret gitlab-webhook-secret já existe, mantendo."
else
  TOKEN=$(openssl rand -hex 20)
  echo "  GUARDE ESTE TOKEN: $TOKEN"
  kubectl -n ci create secret generic gitlab-webhook-secret \
    --from-literal=secretToken="$TOKEN"
fi

echo "== Passo 5 — Pipelines por stack =="
kubectl apply -f "$YAML_CI/pipelines/java-app-pipeline.yaml"
kubectl apply -f "$YAML_CI/pipelines/node-app-pipeline.yaml"

echo "== Passo 6 — Triggers (Binding, Template, Trigger) =="
kubectl apply -f "$YAML_CI/triggers/gitlab-push-binding.yaml"
kubectl apply -f "$YAML_CI/triggers/app-template.yaml"
kubectl apply -f "$YAML_CI/triggers/gitlab-push-trigger.yaml"

echo "== Passo 7 — EventListener + NodePort =="
kubectl apply -f "$YAML_CI/triggers/eventlistener.yaml"

echo "== Aguardando pod do EL ficar Ready =="
kubectl -n ci wait --for=condition=Ready pod -l eventlistener=gitlab-listener --timeout=120s

echo
echo "== Checklist final =="
kubectl -n ci get pipeline,trigger,triggerbinding,triggertemplate,eventlistener,sa,secret,pods
echo
echo "Rode ./scripts/ops/diagnose-el.sh ou um push de teste para validar o roteamento."
