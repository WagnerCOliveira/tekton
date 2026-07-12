#!/usr/bin/env bash
# Coleta logs, describe e eventos do EventListener num único output — primeiro
# passo de diagnóstico quando um webhook não dispara o pipeline esperado.
#
# Uso: ./diagnose-el.sh [--help]

set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Uso: $0"
  echo "Imprime status, describe, logs recentes e eventos do EventListener gitlab-listener."
  exit 0
fi

echo "== Recursos do ci =="
kubectl -n ci get pipeline,trigger,triggerbinding,triggertemplate,eventlistener,sa,secret,pods

echo
echo "== Describe do pod do EL =="
kubectl -n ci describe pod -l eventlistener=gitlab-listener

echo
echo "== Últimas 50 linhas de log do EL =="
kubectl -n ci logs -l eventlistener=gitlab-listener --tail=50

echo
echo "== Eventos recentes do namespace ci =="
kubectl -n ci get events --sort-by=.lastTimestamp | tail -20

echo
echo "== Feature flags do Tekton =="
kubectl -n tekton-pipelines get cm feature-flags -o yaml | grep -E "enable-"

echo
echo "== Interceptors registrados =="
kubectl get clusterinterceptors
