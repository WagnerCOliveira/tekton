#!/usr/bin/env bash
# Lista os PipelineRuns mais recentes em todos os namespaces, ordenados por
# data de criação — útil para ver runs de qualquer projeto de uma vez.
#
# Uso: ./list-all-runs.sh [N] [--help]
#   N  quantidade de linhas a mostrar (default: 20)

set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Uso: $0 [N]"
  echo "Lista os N PipelineRuns mais recentes em todos os namespaces (default N=20)."
  exit 0
fi

N="${1:-20}"

kubectl get pipelinerun -A --sort-by=.metadata.creationTimestamp | tail -n "$N"
