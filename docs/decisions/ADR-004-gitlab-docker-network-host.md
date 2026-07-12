# ADR-004: GitLab CE via Docker Compose com `network_mode: host`

## Status
Aceito

## Data
2026-07-05 (aproximado)

## Contexto
O GitLab CE roda no host (fora do cluster k3s) via Docker Compose, e precisa entregar webhooks HTTP para o `EventListener` exposto via NodePort na rede das VMs k3s (`192.168.56.0/24`). Na configuração padrão do Docker Compose, o container do GitLab fica em uma rede bridge isolada (`172.18.0.0/16`) e **não consegue rotear** para a rede `192.168.56.0/24` das VMs — o webhook falha com `Connection refused` (documentado em `troubleshooting.md` §5.2).

## Decisão
Rodar o container do GitLab com `network_mode: host` no `docker-compose.yml`, eliminando o isolamento de rede Docker e dando ao container acesso direto às interfaces de rede do host (incluindo a rede `virbr1` que chega até as VMs). Como consequência, o bloco `ports:` do compose é removido (incompatível com `network_mode: host`) e a porta de escuta precisa ser configurada explicitamente via `nginx['listen_port']` no `GITLAB_OMNIBUS_CONFIG`.

## Consequências

### Positivas
- Resolve o roteamento sem precisar criar uma rede Docker bridge customizada ou regras de NAT/iptables manuais
- Configuração simples — uma linha (`network_mode: host`) no compose

### Negativas
- Perde o isolamento de rede que o Docker normalmente dá ao container — o GitLab passa a expor todas as portas diretamente no host
- Amarra a solução ao fato de o host e as VMs estarem na mesma máquina física/rede libvirt — não generaliza para GitLab rodando em outra máquina

### Neutras (trade-offs)
- Só faz sentido nesse cenário de laboratório local (GitLab e k3s "vizinhos" via libvirt); em um ambiente real com GitLab gerenciado ou em outra rede, essa decisão não se aplicaria

## Alternativas consideradas
- **Criar rede Docker bridge customizada + rotas entre `172.18.0.0/16` e `192.168.56.0/24`**: mais "correto" do ponto de vista de isolamento, mas exige configuração adicional de rede no host (rotas estáticas ou NAT) que não foi necessária com `network_mode: host`

## Referências
- [`docs/01-infraestrutura-base.md`](../01-infraestrutura-base.md) §8 — "GitLab Community via Docker Compose"
- `troubleshooting.md` §5.2 — "Webhook: Connection refused"
- [GitLab CE Docker](https://docs.gitlab.com/ee/install/docker.html)
