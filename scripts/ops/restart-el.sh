#!/usr/bin/env bash
# Reinicia o pod do EventListener (necessário após qualquer mudança em
# Trigger/TriggerBinding/TriggerTemplate/Secret do webhook) e aguarda voltar Ready.
#
# Uso: ./restart-el.sh [--help]

set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Uso: $0"
  echo "Deleta o pod do EventListener gitlab-listener (namespace ci) e aguarda o novo ficar Ready."
  exit 0
fi

kubectl -n ci delete pod -l eventlistener=gitlab-listener
echo "Aguardando novo pod ficar Ready..."
kubectl -n ci wait --for=condition=Ready pod -l eventlistener=gitlab-listener --timeout=120s
kubectl -n ci get pods -l eventlistener=gitlab-listener
