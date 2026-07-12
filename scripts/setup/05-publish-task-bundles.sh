#!/usr/bin/env bash
# Publica os Task Bundles canônicos (yaml/tasks/*.yaml) no registry interno como
# tags imutáveis. Nunca sobrescreve uma tag em uso — ver ADR-003.
#
# Pré-requisitos: `tkn` CLI instalado; registry acessível.
#
# Uso: ./05-publish-task-bundles.sh [registry:porta] [tag] [--help]
#   registry:porta  default: 192.168.56.110:32000
#   tag              default: v1

set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Uso: $0 [registry:porta] [tag]"
  echo "Publica git-clone, maven-build, node-build e kaniko-build-push como Task Bundles."
  echo "  registry:porta  default: 192.168.56.110:32000"
  echo "  tag              default: v1"
  exit 0
fi

REG="${1:-192.168.56.110:32000}"
TAG="${2:-v1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TASKS_DIR="$REPO_ROOT/yaml/tasks"

for task in git-clone maven-build node-build kaniko-build-push; do
  file="$TASKS_DIR/$task.yaml"
  if [[ ! -f "$file" ]]; then
    echo "ERRO: $file não encontrado." >&2
    exit 1
  fi
  dest="$REG/tekton/$task:$TAG"
  if curl -sf "http://$REG/v2/tekton/$task/tags/list" 2>/dev/null | grep -q "\"$TAG\""; then
    echo "AVISO: $dest já existe — pulando (nunca sobrescrever tag em uso, ver ADR-003)."
    continue
  fi
  echo "== Publicando $dest =="
  tkn bundle push "$dest" -f "$file"
done

echo
echo "== Catálogo atual =="
curl -s "http://$REG/v2/_catalog"
echo
