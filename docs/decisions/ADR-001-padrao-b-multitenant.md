# ADR-001: Adotar padrão B multi-tenant (Pipeline em `ci`, PipelineRuns em `proj-<repo>`)

## Status
Aceito

## Data
2026-07-06 (aproximado — consolidado junto com a reorganização da documentação; a decisão em si já estava implícita no `tekton-ci-playbook.md` do commit inicial de 2026-07-05)

## Contexto
Na configuração original (documentada em [`docs/01-infraestrutura-base.md`](../01-infraestrutura-base.md)), **tudo** ficava no namespace `ci`: Pipeline, Trigger/TriggerBinding/TriggerTemplate/EventListener, secrets (webhook e basic-auth git) e todos os `PipelineRun`. Isso funciona para um único projeto, mas não escala: um segundo time no cluster enxergaria os secrets do primeiro, compartilharia cotas de recurso, e não seria possível aplicar policies distintas por projeto — auditoria vira uma sopa.

Três padrões estavam na mesa (ver análise completa em [`docs/02-arquitetura-multitenant.md`](../02-arquitetura-multitenant.md)):
- **Padrão A** — tudo roda em `ci` (o original)
- **Padrão B** — Pipeline em `ci`, PipelineRuns no namespace do projeto
- **Padrão C** — tudo via Task Bundles (OCI-only), sem Pipelines nativos no cluster

## Decisão
Adotar o **Padrão B**: o Pipeline (definição da esteira) vive em `ci` como catálogo compartilhado por stack; cada `PipelineRun` de aplicação é criado dinamicamente no namespace `proj-<repo>` daquela aplicação, usando a ServiceAccount `pipeline-runner` local e o `cluster resolver` do Tekton para referenciar o Pipeline em `ci`.

## Consequências

### Positivas
- Isolamento por projeto: RBAC, cotas de recurso e secrets ficam contidos em `proj-<repo>`
- O Pipeline continua sendo fonte única de verdade — sem duplicar definição por projeto
- Modelo "plataforma como produto": o time de plataforma dono do `ci` publica Pipelines, os times de aplicação apenas consomem

### Negativas
- Mais complexo que o Padrão A — exige `cluster resolver` habilitado e roteamento CEL para calcular o namespace de destino
- Introduz um novo ponto de falha (CEL mal configurado = todos os runs caem no namespace errado — ver `troubleshooting.md` §7.5)

### Neutras (trade-offs)
- Não é tão portável/GitOps-friendly quanto o Padrão C (bundles-only), mas isso é aceitável no estágio atual (lab / semi-produtivo com poucas equipes)

## Alternativas consideradas
- **Padrão A (tudo em `ci`)**: descartado por falta de isolamento — adequado só para lab de projeto único ou PoC, não para múltiplas equipes
- **Padrão C (tudo via Bundles OCI)**: descartado por ora — máxima portabilidade e versionamento, mas qualquer alteração de Pipeline vira um push de bundle, overhead desnecessário no estágio atual. Fica como possível evolução futura (ver roadmap em `docs/02-arquitetura-multitenant.md` §14)

## Referências
- [`docs/02-arquitetura-multitenant.md`](../02-arquitetura-multitenant.md) — arquitetura completa e playbooks
- [Tekton Cluster Resolver](https://tekton.dev/docs/pipelines/cluster-resolver/)
