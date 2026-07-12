# Architecture Decision Records

Todo ADR começa com o próximo número sequencial disponível (`ADR-006`, `ADR-007`, ...).
Todo ADR nasce em status "Proposto".

## Quando criar um ADR

- Nova convenção que afeta múltiplos projetos
- Mudança de padrão arquitetônico
- Escolha de tecnologia/ferramenta que impacta operação
- Trade-off deliberado em segurança/performance/simplicidade

## Quando NÃO criar

- Escolhas de implementação triviais
- Correções de bug pontuais (esses vão pro [CHANGELOG](../../CHANGELOG.md))
- Onboarding de nova aplicação

## Template

Ver [`_template.md`](_template.md) neste diretório.

## Índice

| ADR | Título | Status |
|---|---|---|
| [ADR-001](ADR-001-padrao-b-multitenant.md) | Adotar padrão B multi-tenant | Aceito |
| [ADR-002](ADR-002-roteamento-cel-prefixo.md) | Roteamento por prefixo do repo via CEL | Aceito |
| [ADR-003](ADR-003-task-bundles-versionados.md) | Task Bundles versionados imutáveis | Aceito |
| [ADR-004](ADR-004-gitlab-docker-network-host.md) | GitLab CE via Docker Compose com `network_mode: host` | Aceito |
| [ADR-005](ADR-005-registry-interno-http.md) | Registry interno HTTP com `registries.yaml` | Aceito |

## Nota sobre `helm-backlog.md`

O documento [`docs/roadmap-helm.md`](../roadmap-helm.md) (ex-`helm-backlog.md`) tem sua própria seção interna "ADR-01 a ADR-05" — são decisões **propostas**, ainda não aceitas, específicas da migração para Helm, numeradas com dois dígitos e vivendo dentro daquele documento (não como arquivo individual aqui). Não confundir com os ADRs de plataforma deste diretório (três dígitos, `ADR-001` em diante). Se algum desses ADRs de Helm for aceito e implementado, ele deve ganhar um arquivo próprio aqui.
