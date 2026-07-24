# Plataforma CI/CD com Tekton — Laboratório k3s

Plataforma de CI/CD **multi-tenant** construída com Tekton em cluster k3s local. Integra GitLab Community Edition via webhooks, um registry Docker interno e pipelines versionados como Task Bundles OCI.

---

## Sobre esta documentação

Este `README.md` é o índice central do projeto. Os documentos técnicos aprofundados vivem em [`docs/`](docs/), scripts operacionais em [`scripts/`](scripts/), manifestos K8s/Tekton canônicos em [`yaml/`](yaml/), e as decisões arquitetônicas em [`docs/decisions/`](docs/decisions/) (ADRs). Todo o histórico de mudanças fica em [`CHANGELOG.md`](CHANGELOG.md).

## Arquitetura

![Diagrama de topologia de rede](imagens/fluxo-do-webhook-ate-a-imagem-publicada.png)

---

## Mapa da documentação

| Documento | O que cobre | Quando ler |
|---|---|---|
| [docs/01-infraestrutura-base.md](docs/01-infraestrutura-base.md) | Infra base: k3s, Tekton, Registry, Task Bundles, GitLab, primeira pipeline | Montando do zero |
| [docs/02-arquitetura-multitenant.md](docs/02-arquitetura-multitenant.md) | Arquitetura multi-tenant: decisão, implementação, multi-stack, onboarding | Evoluindo para multi-tenant |
| [docs/03-onboarding-app-java.md](docs/03-onboarding-app-java.md) | Template copia-e-cola: criar namespace + onboarding de uma nova app Java | Adicionando uma app Java nova |
| [docs/04-ci-operacional.md](docs/04-ci-operacional.md) | Operação do namespace `ci`: inventário, playbooks, diagnóstico | Operando a plataforma |
| [docs/05-troubleshooting.md](docs/05-troubleshooting.md) | Todos os problemas encontrados, organizados por categoria | Investigando um problema |
| [docs/06-diagramas-prompts.md](docs/06-diagramas-prompts.md) | Prompts para gerar diagramas com Gemini/Imagen | Gerando diagramas |
| [docs/07-bootstrap-helm.md](docs/07-bootstrap-helm.md) | Playbook: subir a plataforma inteira via Helm (registry → platform → bundles), na ordem certa | Montando a plataforma do zero via Helm |
| [docs/roadmap-helm.md](docs/roadmap-helm.md) | Backlog completo da migração para Helm (38 histórias, 8 sprints) | Planejando a migração Helm |
| [docs/decisions/](docs/decisions/) | ADRs — por que a arquitetura é do jeito que é | Entender uma decisão passada, ou propor uma nova |
| [CHANGELOG.md](CHANGELOG.md) | Histórico de mudanças versionado (Keep a Changelog + SemVer) | Ver o que mudou recentemente |

### Ordem sugerida de leitura

```
1. docs/01-infraestrutura-base.md     ← monta a infra e valida um ciclo completo
2. docs/02-arquitetura-multitenant.md ← evolui para multi-tenant e onboarda apps
3. docs/04-ci-operacional.md          ← referência operacional da plataforma
4. docs/05-troubleshooting.md         ← quando algo não funciona
```

### Scripts e manifestos

```
scripts/
├── setup/       ← bootstrap da plataforma (01-install-tekton.sh ... 05-publish-task-bundles.sh)
├── ops/         ← operação do dia a dia (diagnose-el.sh, rotate-webhook-token.sh, ...)
└── onboarding/  ← new-app.sh <backend|frontend> <nome>

yaml/
├── ci/          ← Pipelines, RBAC, Triggers e registry do namespace ci (fonte de verdade)
├── projects/    ← template de ServiceAccount para namespaces proj-*
└── tasks/       ← Tasks fonte dos Task Bundles publicados no registry
```

---

## Componentes da plataforma

| Componente | Namespace | Acesso externo | Função |
|---|---|---|---|
| Tekton Pipelines | `tekton-pipelines` | — | Executa Tasks e Pipelines |
| Tekton Triggers | `tekton-pipelines` | — | Recebe eventos HTTP e cria PipelineRuns |
| Tekton Dashboard | `tekton-pipelines` | NodePort **32097** | UI de observabilidade |
| Bundles Resolver | `tekton-pipelines-resolvers` | — | Puxa Task Bundles do registry OCI |
| Docker Registry v2 | `registry` | NodePort **32000** | Armazena bundles e imagens finais |
| EventListener | `ci` | NodePort **32080** | Ponto de entrada dos webhooks |
| GitLab CE | Host (Docker Compose) | **:8929** | SCM e emissor de webhooks |

---

## Topologia de rede

```
Host Notebook
├─ wlo1        192.168.0.13    (Wi-Fi)
│   │
│   └─ GitLab CE (Docker, network_mode: host) → :8929
├─ virbr0      192.168.121.1   (libvirt default)
└─ virbr1      192.168.56.1    (rede das VMs k3s)
    │
    └─ Cluster k3s (192.168.56.0/24)
         ├─ k3s-server   192.168.56.110
         ├─ k3s-agent-1
         └─ k3s-agent-2
               ├─ Registry   → NodePort 32000
               ├─ EL Webhook → NodePort 32080
               └─ Dashboard  → NodePort 32097
```

---

## Convenções vigentes

| Elemento | Padrão | Exemplo |
|---|---|---|
| Repo GitLab — Java/Maven | `backend-<nome>` | `backend-payments` |
| Repo GitLab — Node/Angular | `frontend-<nome>` | `frontend-portal` |
| Namespace de projeto | `proj-<nome-do-repo>` | `proj-backend-payments` |
| ServiceAccount de execução | `pipeline-runner` (fixo por namespace) | — |
| Secret de auth Git | `gitlab-basic-auth` (fixo por namespace) | — |
| Task Bundle | `tekton/<task>:v<N>` | `tekton/git-clone:v1` |
| Imagem publicada | `apps/<repo>:<sha>` | `apps/backend-payments:82a57d1` |
| Portas expostas | 32000 (registry), 32080 (webhook), 32097 (dashboard) | — |

**Por que o prefixo no repo:** o interceptor CEL do EventListener lê `body.project.name` e usa o prefixo para decidir qual Pipeline aplicar. Sem prefixo, o evento é descartado silenciosamente — ver [ADR-002](docs/decisions/ADR-002-roteamento-cel-prefixo.md).

---

## Task Bundles disponíveis

```bash
# Verificar catálogo
curl -s http://192.168.56.110:32000/v2/_catalog

# Listar tags de um bundle
curl -s http://192.168.56.110:32000/v2/tekton/git-clone/tags/list
```

| Bundle | Imagem base | Função |
|---|---|---|
| `tekton/git-clone:v1` | `alpine/git:2.43.0` | Clone + checkout |
| `tekton/maven-build:v1` | `maven:3.9-eclipse-temurin-17` | `mvn clean package` |
| `tekton/node-build:v1` | `node:20-alpine` | `npm install` + `npm run build` |
| `tekton/kaniko-build-push:v1` | `gcr.io/kaniko-project/executor:v1.23.2` | Build + push de imagem |

---

## Início rápido — top comandos

| Preciso... | Comando |
|---|---|
| Ver status geral da plataforma | `./scripts/ops/diagnose-el.sh` |
| Adicionar uma nova app | `PAT=<pat> ./scripts/onboarding/new-app.sh backend <nome>` — ver [docs/03-onboarding-app-java.md](docs/03-onboarding-app-java.md) |
| Ver os últimos runs | `./scripts/ops/list-all-runs.sh` |
| Recuperar o EL (após mudar Trigger/Secret) | `./scripts/ops/restart-el.sh` |
| Acessar o dashboard | `http://192.168.56.110:32097` |

## Checklist rápido — adicionar uma nova app

```
[ ] Criar repo no GitLab com prefixo backend- ou frontend-
[ ] Gerar PAT (scope: read_repository)
[ ] kubectl create ns proj-<repo>
[ ] Criar secret gitlab-basic-auth com o PAT + anotação tekton.dev/git-0
[ ] Criar ServiceAccount pipeline-runner com o secret anexado
[ ] Cadastrar webhook no GitLab → http://192.168.56.110:32080
[ ] Garantir Dockerfile na raiz do repo
[ ] git push → pipeline roda automaticamente
```

Tempo estimado: ~5 minutos por app. Automatizável via `scripts/onboarding/new-app.sh` (webhook e push continuam manuais).

---

## O que mudou recente

Últimas mudanças arquitetônicas significativas. Para histórico completo, ver [CHANGELOG.md](CHANGELOG.md).

| Data | Mudança | Impacto | Link |
|---|---|---|---|
| 2026-07-12 | Consolidação da documentação: `docs/`, `scripts/`, `yaml/`, ADRs, CHANGELOG | Estrutura fixa para navegar a documentação e operar a plataforma via script em vez de copiar/colar heredocs | [_workspace/CONSOLIDATION-REPORT.md](_workspace/CONSOLIDATION-REPORT.md) |
| 2026-07-06 (aproximado) | Roteamento CEL por prefixo (`frontend-*`/`backend-*`) | Plataforma passou a suportar múltiplas stacks a partir de um único EventListener | [ADR-002](docs/decisions/ADR-002-roteamento-cel-prefixo.md) |
| 2026-07-05/06 (aproximado) | Padrão B multi-tenant adotado | Cada projeto tem seu namespace isolado (`proj-<repo>`); Pipeline permanece compartilhado em `ci` | [ADR-001](docs/decisions/ADR-001-padrao-b-multitenant.md) |

---

## Estratégia de evolução

- Decisões arquitetônicas (convenções que afetam múltiplos projetos, mudança de padrão, escolha de tecnologia) viram um **ADR** em [`docs/decisions/`](docs/decisions/) — ver o [índice](docs/decisions/README.md) e o [template](docs/decisions/_template.md).
- Todo o resto (correções, novas features operacionais) entra no [`CHANGELOG.md`](CHANGELOG.md).
- Onboarding de app nova **não** gera entrada no CHANGELOG — é operação corrente, coberta pelo checklist acima.

## Roadmap

1. **Helm** — migrar toda a configuração para charts Helm (ver [docs/roadmap-helm.md](docs/roadmap-helm.md))
2. **Testes** — Task `maven-test` antes do build, JaCoCo para coverage
3. **CD com ArgoCD** — repo GitOps + Applications sincronizando manifests
4. **Segurança** — Trivy scan na imagem, Cosign para assinatura
5. **Observabilidade** — Prometheus + Grafana + Loki
6. **Promoção entre ambientes** — dev → staging → prod via MR
