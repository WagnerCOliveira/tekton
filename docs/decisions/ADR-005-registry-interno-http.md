# ADR-005: Registry interno HTTP com `registries.yaml` inseguro

## Status
Aceito

## Data
2026-07-05 (aproximado)

## Contexto
O cluster precisa de um lugar para armazenar Task Bundles e as imagens de aplicação publicadas pelo Kaniko. Em um laboratório local, provisionar TLS (certificados, CA própria ou Let's Encrypt com DNS público) para um registry interno é overhead desproporcional ao valor no estágio atual.

## Decisão
Rodar o `registry:2` (Docker Registry v2) sem TLS, exposto via NodePort, e configurar cada um dos 3 nós do k3s (`server` + 2 `agents`) com `/etc/rancher/k3s/registries.yaml` marcando o registry como inseguro (`insecure_skip_verify: true`), com **duas entradas** — o DNS interno do cluster (`registry.registry.svc.cluster.local:5000`) e o `IP:NodePort` (`192.168.56.110:32000`) — já que ambas as formas de acesso são usadas (Pipelines usam o DNS interno, comandos manuais/`tkn` usam o IP:NodePort).

## Consequências

### Positivas
- Zero overhead de gestão de certificados
- Funciona igual em qualquer um dos 3 nós assim que o `registries.yaml` é replicado e o k3s reiniciado

### Negativas
- Sem TLS, sem autenticação — qualquer coisa com acesso de rede ao NodePort 32000 pode ler/escrever no registry
- Cada novo nó do cluster precisa lembrar de replicar o `registries.yaml` manualmente (documentado como causa recorrente de erro em `troubleshooting.md` §2.1/§2.2 quando isso é esquecido)

### Neutras (trade-offs)
- Aceitável para lab isolado sem exposição externa; **não é adequado para produção** — ver alternativas abaixo como caminho de evolução

## Alternativas consideradas
- **Harbor com TLS**: solução completa (auth, scanning, replicação), mas overhead de operação desproporcional para o estágio atual de laboratório
- **Registry externo autenticado** (ex.: GitLab Container Registry do próprio GitLab CE já rodando): evita manter um segundo registry, mas acopla a disponibilidade do build ao GitLab e exige lidar com autenticação Docker (`imagePullSecrets`) em vez do inseguro atual — candidato natural para quando a plataforma sair do estágio de lab

## Referências
- [`docs/01-infraestrutura-base.md`](../01-infraestrutura-base.md) §5 — "Registry interno no cluster"
- `troubleshooting.md` §2 — "Registry Docker interno"
- [k3s registries.yaml](https://docs.k3s.io/installation/private-registry)
