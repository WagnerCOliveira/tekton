#!/usr/bin/env bash
# Cria o namespace, secret e ServiceAccount de uma nova aplicação na plataforma
# multi-tenant (Padrão B). NÃO cadastra o webhook no GitLab nem faz o primeiro
# push — essas duas etapas continuam manuais (ver docs/03-onboarding-app-java.md
# e docs/02-arquitetura-multitenant.md §12).
#
# Pré-requisitos: kubectl configurado; PAT do GitLab já gerado (scope read_repository).
#
# Uso: ./new-app.sh <backend|frontend> <nome> [--help]
#   backend|frontend   stack da app — define o prefixo do repo (obrigatório p/ o CEL)
#   nome               nome curto da app, sem prefixo (ex.: payments)
#
# Variáveis de ambiente opcionais:
#   GITLAB_URL   (default: http://192.168.56.1:8929)
#   GITLAB_USER  (default: root)
#   PAT          (obrigatória — Personal Access Token com scope read_repository)

set -euo pipefail

usage() {
  echo "Uso: $0 <backend|frontend> <nome>"
  echo
  echo "  backend|frontend   stack da app (define o prefixo do repo: backend-/frontend-)"
  echo "  nome               nome curto da app, sem prefixo (ex.: payments)"
  echo
  echo "Variáveis de ambiente:"
  echo "  GITLAB_URL   default: http://192.168.56.1:8929"
  echo "  GITLAB_USER  default: root"
  echo "  PAT          obrigatória — Personal Access Token (scope read_repository)"
}

if [[ "${1:-}" == "--help" || $# -lt 2 ]]; then
  usage
  [[ "${1:-}" == "--help" ]] && exit 0 || exit 1
fi

STACK="$1"
APP_NAME="$2"

if [[ "$STACK" != "backend" && "$STACK" != "frontend" ]]; then
  echo "ERRO: stack inválida '$STACK'. Use 'backend' ou 'frontend'." >&2
  usage
  exit 1
fi

if [[ -z "${PAT:-}" ]]; then
  echo "ERRO: variável PAT não definida (Personal Access Token, scope read_repository)." >&2
  exit 1
fi

GITLAB_URL="${GITLAB_URL:-http://192.168.56.1:8929}"
GITLAB_USER="${GITLAB_USER:-root}"
REPO_NAME="${STACK}-${APP_NAME}"
NAMESPACE="proj-${REPO_NAME}"

echo "== Provisionando $NAMESPACE (stack: $STACK, repo: $REPO_NAME) =="

kubectl create ns "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label ns "$NAMESPACE" \
  tekton.dev/project=true \
  app="$REPO_NAME" \
  stack="$STACK" \
  --overwrite

kubectl -n "$NAMESPACE" create secret generic gitlab-basic-auth \
  --type=kubernetes.io/basic-auth \
  --from-literal=username="$GITLAB_USER" \
  --from-literal=password="$PAT" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" annotate secret gitlab-basic-auth \
  tekton.dev/git-0="$GITLAB_URL" --overwrite

NAMESPACE="$NAMESPACE" envsubst < "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../yaml/projects/pipeline-runner-sa.yaml.tpl" \
  | kubectl apply -f -

echo
echo "== Validação =="
kubectl -n "$NAMESPACE" get sa,secret

echo
echo "Próximos passos manuais:"
echo "  1. Cadastrar o webhook no GitLab (${REPO_NAME}) -> URL http://192.168.56.110:32080"
echo "     Token: ./scripts/ops/show-webhook-token.sh"
echo "  2. Garantir Dockerfile na raiz do repo"
echo "  3. git push -- o CEL roteia automaticamente pelo prefixo '${STACK}-'"
