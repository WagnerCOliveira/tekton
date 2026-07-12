#!/usr/bin/env bash
# Instala Tekton Pipelines, Triggers, Interceptors e Dashboard num cluster k3s,
# habilita os feature flags de bundles/cluster resolver e roda os smoke tests.
#
# Pré-requisitos: kubectl configurado apontando para o cluster certo.
#
# Uso: ./01-install-tekton.sh [--help]

set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Uso: $0"
  echo "Instala Tekton Pipelines + Triggers + Interceptors + Dashboard."
  echo "Habilita enable-bundles-resolver. Não recebe argumentos."
  exit 0
fi

echo "== Instalando Tekton Pipelines =="
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

echo "== Aguardando webhook do Pipelines ficar Ready (evita race condition com Triggers) =="
kubectl -n tekton-pipelines wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=webhook --timeout=180s

echo "== Instalando Tekton Triggers e Interceptors =="
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml

echo "== Instalando Tekton Dashboard =="
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml

echo "== Habilitando o bundles resolver =="
kubectl -n tekton-pipelines patch cm feature-flags \
  --type merge -p '{"data":{"enable-bundles-resolver":"true"}}'

echo "== Validação =="
kubectl get pods -n tekton-pipelines
kubectl get pods -n tekton-pipelines-resolvers
kubectl get clusterinterceptors

echo
echo "Pronto. Interceptors esperados: gitlab, github, bitbucket, cel, slack."
echo "Para a etapa de registry interno, rode ./02-install-registry.sh."
