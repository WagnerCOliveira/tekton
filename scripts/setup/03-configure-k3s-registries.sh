#!/usr/bin/env bash
# Escreve /etc/rancher/k3s/registries.yaml no nó local e reinicia o serviço k3s
# correspondente, para que containerd aceite pull HTTP (sem TLS) do registry interno.
#
# ATENÇÃO: precisa ser executado em CADA um dos 3 nós do cluster (server + 2 agents),
# com sudo. Este script só cobre um nó por execução — rode-o localmente em cada VM.
#
# Uso: ./03-configure-k3s-registries.sh [server|agent] [--help]
#   server  -> reinicia o serviço k3s (padrão se omitido e o binário k3s-server existir)
#   agent   -> reinicia o serviço k3s-agent

set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
  echo "Uso: $0 [server|agent]"
  echo "Escreve /etc/rancher/k3s/registries.yaml e reinicia o k3s (server) ou k3s-agent."
  echo "Rodar em CADA nó do cluster, com sudo."
  exit 0
fi

ROLE="${1:-server}"
if [[ "$ROLE" != "server" && "$ROLE" != "agent" ]]; then
  echo "ERRO: argumento inválido '$ROLE'. Use 'server' ou 'agent'." >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERRO: rode como root/sudo (precisa escrever em /etc/rancher/k3s/)." >&2
  exit 1
fi

REGISTRY_DNS="registry.registry.svc.cluster.local:5000"
REGISTRY_IP="192.168.56.110:32000"

echo "== Escrevendo /etc/rancher/k3s/registries.yaml =="
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/registries.yaml <<EOF
mirrors:
  "${REGISTRY_DNS}":
    endpoint:
      - "http://${REGISTRY_DNS}"
  "${REGISTRY_IP}":
    endpoint:
      - "http://${REGISTRY_IP}"
configs:
  "${REGISTRY_DNS}":
    tls:
      insecure_skip_verify: true
  "${REGISTRY_IP}":
    tls:
      insecure_skip_verify: true
EOF

if [[ "$ROLE" == "server" ]]; then
  echo "== Reiniciando k3s (server) =="
  systemctl restart k3s
else
  echo "== Reiniciando k3s-agent =="
  systemctl restart k3s-agent
fi

echo
echo "Feito. Confirme com: cat /etc/rancher/k3s/registries.yaml"
