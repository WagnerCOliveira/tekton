#!/usr/bin/env bash
# Rotaciona o token do webhook compartilhado (gitlab-webhook-secret) sem derrubar
# a plataforma. Depois de rodar, é preciso atualizar MANUALMENTE o Secret Token
# de cada webhook cadastrado no GitLab (não há API automatizada aqui de propósito
# — trocar o token de cada projeto é uma ação deliberada, não em massa).
#
# Uso: ./rotate-webhook-token.sh [--help]

set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Uso: $0"
  echo "Gera um novo token, atualiza gitlab-webhook-secret e reinicia o EL."
  echo "Depois, atualize manualmente o Secret Token de cada webhook no GitLab."
  exit 0
fi

NEW_TOKEN=$(openssl rand -hex 20)
echo "NOVO TOKEN: $NEW_TOKEN"

kubectl -n ci create secret generic gitlab-webhook-secret \
  --from-literal=secretToken="$NEW_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Reiniciando o EL para carregar o novo token..."
kubectl -n ci delete pod -l eventlistener=gitlab-listener

echo
echo "ATENÇÃO: os webhooks existentes vão começar a falhar até você atualizar"
echo "cada um no GitLab (Settings → Webhooks → Edit → colar o novo token → Save)."
