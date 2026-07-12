#!/usr/bin/env bash
# Faz o deploy do Docker Registry v2 interno (namespace `registry`, NodePort 32000)
# e valida que o endpoint /v2/ responde.
#
# Pré-requisitos: kubectl configurado; manifesto em yaml/ci/registry.yaml.
#
# Uso: ./02-install-registry.sh [--help]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST="$REPO_ROOT/yaml/ci/registry.yaml"

if [[ "${1:-}" == "--help" ]]; then
  echo "Uso: $0"
  echo "Aplica $MANIFEST e valida o endpoint /v2/ do registry interno."
  exit 0
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "ERRO: manifesto não encontrado em $MANIFEST" >&2
  exit 1
fi

echo "== Aplicando $MANIFEST =="
kubectl apply -f "$MANIFEST"

echo "== Aguardando pod do registry ficar Ready =="
kubectl -n registry wait --for=condition=Ready pod -l app=registry --timeout=120s

IP_SERVER=$(kubectl get node k3s-server -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "== Validando http://$IP_SERVER:32000/v2/ (esperado: {}) =="
curl -sf "http://$IP_SERVER:32000/v2/" && echo

echo
echo "Registry pronto em $IP_SERVER:32000."
echo "Próximo passo: configurar /etc/rancher/k3s/registries.yaml em cada nó (./03-configure-k3s-registries.sh)."
