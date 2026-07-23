# ADR-007: Manter GitLab CI conforme o roadmap, mesmo com o repo no GitHub — e assumir as limitações de infra do Sprint 8

## Status
Aceito

## Data
2026-07-23

## Contexto
`docs/roadmap-helm.md` especifica o Épico 8 (Sprint 8, HLM-33 a HLM-35) em termos de **GitLab CI**: `helm lint`/`helm template` em todo PR (HLM-33), `helm upgrade --install --dry-run` contra um cluster de teste (HLM-34), e um Pipeline Tekton que publica os próprios charts como artefatos OCI (HLM-35).

Duas coisas quebram a premissa implícita do roadmap ao implementar isso de verdade:

1. **Este repositório vive no GitHub** (`github.com/WagnerCOliveira/tekton`), não num GitLab. Um `.gitlab-ci.yml` neste repo não dispara nada a menos que o repo seja espelhado ou migrado para um GitLab com runner configurado.
2. **O cluster k3s e o GitLab CE do lab estão numa rede local isolada** (`192.168.56.0/24`, VMs libvirt) — sem exposição à internet. Um runner de CI hospedado na nuvem (GitLab.com, GitHub Actions) não tem rota até essa rede. Isso afeta diretamente:
   - HLM-34 (`dry-run` contra cluster de teste) — precisa de um runner com rota até o cluster, que não existe
   - HLM-35 (Pipeline Tekton publicando os charts) — o Pipeline em si roda *dentro* do cluster (isso funciona), mas não há como disparar/observar esse Pipeline a partir de um runner de CI externo sem a mesma rota de rede

## Decisão
Implementar HLM-33/34/35 **como especificado no roadmap** (mantendo `.gitlab-ci.yml`, não migrar para GitHub Actions), mas:

- **HLM-33** funciona de verdade em qualquer runner GitLab genérico — `helm lint`/`helm template` são herméticos (não tocam cluster nem rede do lab). Validado localmente reproduzindo os comandos exatos do `.gitlab-ci.yml` via `alpine/helm:3.14.4` em Docker.
- **HLM-34** os jobs de `dry-run` existem no `.gitlab-ci.yml`, mas como `when: manual` + `allow_failure: true`, com uma guarda que falha rápido e explica o motivo (variável `KUBECONFIG_TEST_CLUSTER` ausente) em vez de fingir sucesso ou tentar rodar contra o cluster errado.
- **HLM-35** o Task (`yaml/tasks/helm-chart-publish.yaml`) e o Pipeline (`yaml/ci/pipelines/publish-helm-charts-pipeline.yaml`) existem e seguem os mesmos padrões usados no resto do repo (Task Bundles, ADR-003/ADR-005), mas **não foram testados contra um cluster real** — só validados como YAML sintaticamente correto. Não há schema Tekton disponível offline para uma validação mais forte (tentado via `kubeconform`, sem schema publicado para `Task`/`Pipeline` do Tekton).

Em resumo: a estrutura fica pronta e documentada, mas o Sprint 8 é o primeiro desta migração em que **nada foi validado contra um cluster ou GitLab real** — todos os sprints anteriores tinham pelo menos `helm lint`/`helm template` rodando contra o chart real. Isso é uma mudança de natureza da validação, registrada aqui para não ser confundida com os sprints anteriores.

## Consequências

### Positivas
- O roadmap original fica implementado ao pé da letra — se o repo um dia for espelhado pra um GitLab com runner próprio (ex.: o GitLab CE deste mesmo lab, hoje usado só para os repos das apps `backend-*`/`frontend-*`), o `.gitlab-ci.yml` funciona sem alteração
- HLM-33 entrega valor real hoje mesmo sem GitLab — os comandos nele documentados são exatamente os que qualquer contribuidor deveria rodar localmente antes de um PR
- A guarda explícita em HLM-34 (falha com mensagem clara) é mais segura que um job que silenciosamente teria sido pulado ou que rodaria contra infraestrutura errada

### Negativas
- HLM-34 e HLM-35 são, na prática, **não executáveis** neste ambiente até que alguém configure um runner self-hosted com rota até `192.168.56.0/24` — o valor imediato deles é zero até essa peça de infra existir
- Risco de bit-rot: `yaml/tasks/helm-chart-publish.yaml` e o Pipeline associado podem quebrar silenciosamente com o tempo (ex.: uma flag do `helm push` mudar numa versão futura) sem que ninguém perceba, já que nada os executa

### Neutras (trade-offs)
- Migrar para GitHub Actions resolveria o problema (1) mas não o (2) — a limitação de rede é a mesma independente da plataforma de CI escolhida, então não haveria ganho real em trocar agora

## Alternativas consideradas
- **Migrar para GitHub Actions**: mais coerente com onde o código realmente vive, mas não resolve a limitação de rede (2) e diverge do roadmap sem necessidade — descartada
- **Pular HLM-34/HLM-35 até existir um runner self-hosted**: mais honesto sobre "não fazer trabalho não testável", mas deixa o roadmap incompleto sem necessidade — a estrutura documentada aqui já deixa tudo pronto pro dia em que o runner existir, custo baixo de manter
- **Fingir que foi testado**: nunca considerada — contraria o padrão de honestidade sobre limitações já estabelecido nos ADRs anteriores desta migração (ex.: HLM-30 em `charts/tekton-registry/values.yaml`, também não validado contra cluster real)

## Referências
- `docs/roadmap-helm.md` — Épico 8, backlog original de HLM-33 a HLM-35
- `.gitlab-ci.yml` — implementação de HLM-33/HLM-34
- `yaml/tasks/helm-chart-publish.yaml`, `yaml/ci/pipelines/publish-helm-charts-pipeline.yaml` — implementação de HLM-35
- `docs/04-ci-operacional.md` §11 — playbook de disparo manual do Pipeline de publicação
- ADR-003 (Task Bundles versionados) e ADR-005 (Registry interno HTTP) — padrões reaproveitados por HLM-35
