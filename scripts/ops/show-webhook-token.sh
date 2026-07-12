#!/usr/bin/env bash
# Mostra o token atual do secret gitlab-webhook-secret (namespace ci), usado para
# cadastrar/conferir o webhook em cada projeto do GitLab.
#
# Uso: ./show-webhook-token.sh [--help]

set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Uso: $0"
  echo "Imprime o token de gitlab-webhook-secret (namespace ci) em texto plano."
  exit 0
fi

kubectl -n ci get secret gitlab-webhook-secret \
  -o jsonpath='{.data.secretToken}' | base64 -d
echo
