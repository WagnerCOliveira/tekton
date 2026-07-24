# Backlog — Migração para Helm

Consolidação de todos os recursos Kubernetes da plataforma Tekton em Helm charts, eliminando YAML manual e IPs hardcoded. Este documento é o backlog completo de implementação.

> **Status: 38/38 histórias concluídas (2026-07-23).** Sprints 2 a 8 implementados — ver `CHANGELOG.md` para o detalhe de cada sprint e `docs/decisions/` (ADR-006, ADR-007) para as decisões que saíram do escopo original. Este documento fica como registro histórico do planejamento; o estado atual dos charts é a fonte de verdade (`charts/`).

---

## Sumário

1. [Inventário completo do que será Helm-ificado](#1-inventário-completo-do-que-será-helm-ificado)
2. [Arquitetura dos charts proposta](#2-arquitetura-dos-charts-proposta)
3. [Valores parametrizáveis — problemas atuais](#3-valores-parametrizáveis--problemas-atuais)
4. [Decisões de arquitetura (ADRs)](#4-decisões-de-arquitetura-adrs)
5. [Backlog — Épicos e histórias](#5-backlog--épicos-e-histórias)
6. [Estrutura de values.yaml (schema central)](#6-estrutura-de-valuesyaml-schema-central)
7. [Ordem de implementação](#7-ordem-de-implementação)

---

## 1. Inventário completo do que será Helm-ificado

Tudo que hoje é aplicado via `kubectl apply`, scripts shell ou documentação manual.

### 1.1. Tekton — instalação (hoje: `kubectl apply -f <URL>`)

| Componente | URL atual | Solução Helm |
|---|---|---|
| Tekton Pipelines | `storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml` | Chart wrapper ou dependency |
| Tekton Triggers | `storage.googleapis.com/tekton-releases/triggers/latest/release.yaml` | Chart wrapper ou dependency |
| Tekton Interceptors | `storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml` | Junto com Triggers |
| Tekton Dashboard | `storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml` | Chart wrapper ou dependency |

### 1.2. Registry Docker v2 (hoje: `kubectl apply -f registry.yaml`)

| Recurso | Namespace | Valores hardcoded |
|---|---|---|
| Namespace | `registry` | — |
| PersistentVolumeClaim | `registry` | `storage: 20Gi` |
| Deployment | `registry` | `image: registry:2` |
| Service NodePort | `registry` | `nodePort: 32000` |

### 1.3. Feature flags do Tekton (hoje: `kubectl patch cm`)

| ConfigMap | Chave | Valor |
|---|---|---|
| `feature-flags` (ns `tekton-pipelines`) | `enable-bundles-resolver` | `true` |
| `feature-flags` (ns `tekton-pipelines`) | `enable-cluster-resolver` | `true` |
| `cluster-resolver-config` (ns `tekton-pipelines-resolvers`) | `default-namespace` / `allowed-namespaces` | `"ci"` |

### 1.4. Namespace `ci` — plataforma (hoje: kubectl apply manual por arquivo)

| Recurso | Nome | Valores hardcoded |
|---|---|---|
| Namespace | `ci` | label `tekton.dev/role=platform` |
| ServiceAccount | `tekton-triggers-sa` | — |
| RoleBinding | `tekton-triggers-eventlistener-binding` | ClusterRole fixo |
| ClusterRoleBinding | `tekton-triggers-sa-cluster` | ClusterRole fixo |
| ClusterRole | `tekton-triggers-create-pipelinerun` | verbos fixos |
| ClusterRoleBinding | `tekton-triggers-sa-create-pipelinerun` | SA e ClusterRole fixos |
| Secret | `gitlab-webhook-secret` | token gerado manualmente |
| Pipeline | `java-app-pipeline` | URL do registry hardcoded |
| Pipeline | `node-app-pipeline` | URL do registry hardcoded |
| TriggerBinding | `gitlab-push-binding` | — |
| TriggerTemplate | `app-template` | URL do registry hardcoded, SA hardcoded |
| Trigger | `gitlab-push-trigger` | prefixos CEL hardcoded (`frontend-`, `backend-`) |
| EventListener | `gitlab-listener` | — |
| Service NodePort | `el-gitlab-listener-np` | `nodePort: 32080` |

### 1.5. Task Bundles (hoje: `tkn bundle push` manual)

| Bundle | Tag atual | Imagem base |
|---|---|---|
| `tekton/git-clone` | `v1` | `alpine/git:2.43.0` |
| `tekton/maven-build` | `v1` | `maven:3.9-eclipse-temurin-17` |
| `tekton/node-build` | `v1` | `node:20-alpine` |
| `tekton/kaniko-build-push` | `v1` | `gcr.io/kaniko-project/executor:v1.23.2` |

### 1.6. Namespace de projeto `proj-*` (hoje: 4 comandos kubectl por app)

| Recurso | Valores hardcoded |
|---|---|
| Namespace | nome, labels `tekton.dev/project` e `app` |
| Secret `gitlab-basic-auth` | username `root`, PAT passado na mão |
| Annotation no Secret | URL do GitLab: `http://192.168.0.13:8929` |
| ServiceAccount `pipeline-runner` | referência ao secret |

### 1.7. Tekton Dashboard — exposição NodePort (hoje: `kubectl apply` inline)

| Recurso | Valor hardcoded |
|---|---|
| Service NodePort | `nodePort: 32097` |

---

## 2. Arquitetura dos charts proposta

```
charts/
├── tekton-registry/       # Docker Registry v2 no cluster
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── namespace.yaml
│       ├── pvc.yaml
│       ├── deployment.yaml
│       └── service.yaml
│
├── tekton-platform/       # Namespace ci: RBAC, Pipelines, Triggers, EL
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── namespace.yaml
│       ├── configmap-cluster-resolver.yaml
│       ├── rbac/
│       │   ├── serviceaccount.yaml
│       │   ├── rolebinding.yaml
│       │   ├── clusterrole-create-pipelinerun.yaml
│       │   └── clusterrolebindings.yaml     (2 CRBs)
│       ├── secret-webhook.yaml
│       ├── pipelines/
│       │   └── pipeline.yaml                (loop via .Values.stacks)
│       ├── triggers/
│       │   ├── triggerbinding.yaml
│       │   ├── triggertemplate.yaml
│       │   ├── trigger.yaml                 (CEL gerado via stacks)
│       │   └── eventlistener.yaml
│       └── service-nodeport.yaml
│
├── tekton-bundles/        # Jobs que publicam Task Bundles no registry
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── configmap-tasks/                 (um por bundle)
│       │   ├── git-clone-task.yaml
│       │   ├── maven-build-task.yaml
│       │   ├── node-build-task.yaml
│       │   └── kaniko-task.yaml
│       └── job-bundle-push.yaml             (loop via .Values.bundles)
│
├── tekton-project/        # Template para onboarding de proj-*
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── namespace.yaml
│       ├── secret.yaml
│       └── serviceaccount.yaml
│
└── tekton-lab/            # Umbrella chart (agrupa tudo)
    ├── Chart.yaml         (dependencies: registry, platform, bundles)
    ├── values.yaml        (valores globais centrais)
    └── templates/
        └── _helpers.tpl
```

### Instalação de cada chart

> ⚠️ Exemplo do planejamento original — cita um chart `tekton-lab` (umbrella) que nunca foi criado e usa `-f values-lab.yaml` em charts que não consomem esse arquivo. Para o playbook de bootstrap atual e testado, ver [docs/07-bootstrap-helm.md](07-bootstrap-helm.md).

```bash
# Registry
helm upgrade --install tekton-registry ./charts/tekton-registry \
  -f values-lab.yaml

# Plataforma (namespace ci)
helm upgrade --install tekton-platform ./charts/tekton-platform \
  -f values-lab.yaml

# Task Bundles
helm upgrade --install tekton-bundles ./charts/tekton-bundles \
  -f values-lab.yaml

# Projeto (por app — chamado uma vez por projeto)
helm upgrade --install proj-backend-payments ./charts/tekton-project \
  --set project.name=backend-payments \
  --set project.gitlabPAT=<PAT> \
  -f values-lab.yaml
```

---

## 3. Valores parametrizáveis — problemas atuais

Tudo que está hardcoded hoje e precisa virar `values.yaml`:

| Categoria | Valor atual | Chave proposta |
|---|---|---|
| **Rede** | `192.168.0.13` (GitLab host) | `global.gitlab.host` |
| **Rede** | `192.168.56.110` (k3s server IP) | `global.cluster.serverIP` |
| **Rede** | `8929` (GitLab porta) | `global.gitlab.port` |
| **Portas** | `32000` (Registry NodePort) | `registry.service.nodePort` |
| **Portas** | `32080` (EventListener NodePort) | `platform.eventListener.nodePort` |
| **Portas** | `32097` (Dashboard NodePort) | `dashboard.service.nodePort` |
| **Registry** | `registry.registry.svc.cluster.local:5000` | `global.registry.internalURL` |
| **Bundles** | prefixo `tekton/` | `platform.bundles.prefix` |
| **Bundles** | tag `:v1` | por bundle: `bundles.<name>.tag` |
| **Imagens** | `alpine/git:2.43.0` | `bundles.gitClone.image` |
| **Imagens** | `maven:3.9-eclipse-temurin-17` | `bundles.mavenBuild.image` |
| **Imagens** | `node:20-alpine` | `bundles.nodeBuild.image` |
| **Imagens** | `gcr.io/kaniko-project/executor:v1.23.2` | `bundles.kaniko.image` |
| **CEL** | prefixos `frontend-`, `backend-` | `platform.stacks[].prefix` |
| **CEL** | pipeline por prefixo | `platform.stacks[].pipelineName` |
| **Storage** | `20Gi` (registry PVC) | `registry.storage.size` |
| **Storage** | `2Gi` (workspace PVC por run) | `platform.workspace.size` |
| **GitLab** | `root` (username) | `global.gitlab.username` |

---

## 4. Decisões de arquitetura (ADRs)

### ADR-01: Instalação do Tekton — wrapper vs. chart comunitário

**Contexto:** Tekton não tem charts Helm oficiais. Há charts comunitários mantidos pela CDF/comunidade.

**Opções:**
- A) **Chart comunitário** (`cdf/tekton-pipeline`, `cdf/tekton-triggers`) via dependency
- B) **Helm wrapper** — baixar os YAMLs upstream e aplicá-los como raw resources dentro de um chart
- C) **Manter kubectl apply** e só Helm-ificar o restante

**Decisão recomendada: Opção A + C híbrido**
- Usar charts comunitários para instalação do core Tekton (Pipelines + Triggers)
- Se não estiverem atualizados o suficiente, usar C (install script separado) e Helm apenas para a camada de plataforma
- **Rationale:** a instalação do Tekton é eventual (uma vez por cluster); a camada de plataforma muda frequentemente

**Impacto:** Story HLM-02 (avaliação dos charts comunitários antes de decidir)

---

### ADR-02: Task Bundles — Jobs vs. pipeline local

**Contexto:** `tkn bundle push` precisa de acesso ao registry e ao `tkn` CLI. Não é um recurso Kubernetes nativo.

**Opções:**
- A) **Kubernetes Job** com imagem `ghcr.io/tektoncd/cli` — roda dentro do cluster, acesso nativo ao registry
- B) **Helm hook** (pre-install Job) — roda antes dos outros recursos
- C) **Pipeline Tekton** — meta-pipeline que publica os bundles

**Decisão recomendada: Opção A + B**
- Job com Helm hook `pre-install, pre-upgrade`
- A imagem do Job contém o `tkn` CLI e os YAML das Tasks embutidos via ConfigMap
- Job verifica se o bundle já existe (via `/v2/<name>/tags/list`) antes de publicar — idempotente

**Impacto:** Stories HLM-12 a HLM-15

---

### ADR-03: Secrets — Helm values vs. external-secrets

**Contexto:** o PAT do GitLab e o token do webhook não devem ficar em `values.yaml` em plaintext no repositório.

**Opções:**
- A) **Helm values** com `--set project.gitlabPAT=...` (nunca commitar o PAT)
- B) **Sealed Secrets** — criptografar o secret antes de commitar
- C) **External Secrets Operator** — buscar de Vault/AWS Secrets Manager/etc.
- D) **Terraform** para provisionar os secrets antes do Helm

**Decisão recomendada para lab: Opção A**
Passar via `--set` ou `values-local.yaml` (gitignored). Para produção, evoluir para B ou C.

**Impacto:** Story HLM-22 (documentar abordagem de secrets)

---

### ADR-04: Multi-projeto — uma release por projeto vs. um loop no chart

**Contexto:** cada app nova precisa de namespace, SA, secret. Como modelar isso em Helm?

**Opções:**
- A) **Uma release Helm por projeto** — `helm install proj-<nome> ./tekton-project --set ...`
- B) **Loop no values** — uma release com `projects: [...]` que cria todos os namespaces
- C) **Helmfile** — orquestra múltiplas releases Helm via arquivo declarativo

**Decisão recomendada: Opção C (Helmfile)**
- Helmfile com um bloco por projeto; a `tekton-project` chart é reutilizada N vezes
- Adicionar projeto = adicionar bloco no Helmfile
- **Rationale:** uma única release com loop dificulta gerenciar secrets por projeto; Helmfile mantém isolamento

**Impacto:** Stories HLM-19, HLM-20, HLM-21

---

### ADR-05: CEL Trigger dinâmico — template Helm vs. arquivo estático

**Contexto:** o CEL do Trigger precisa listar os prefixos por stack. Hoje é hardcoded.

**Decisão recomendada:**
```yaml
# values.yaml
platform:
  stacks:
    - prefix: "backend-"
      pipelineName: "java-app-pipeline"
    - prefix: "frontend-"
      pipelineName: "node-app-pipeline"
```

O template Helm gera o `filter` e os `overlays` dinamicamente via range. Adicionar Python = adicionar uma linha no values.

**Impacto:** Story HLM-10

---

## 5. Backlog — Épicos e histórias

### Épico 0 — Fundação e estrutura

| ID | História | Critério de aceite | Deps | Prio | Esforço |
|---|---|---|---|---|---|
| HLM-01 | Criar repositório `tekton-charts` com estrutura base de diretórios (charts/, helmfile.yaml, values-lab.yaml) | Repositório com estrutura validada pelo `helm lint` | — | Alta | P |
| HLM-02 | Avaliar charts comunitários do Tekton (cdf/tekton-pipeline, cdf/tekton-triggers) e decidir: usar como dependency ou manter install script | ADR atualizado com decisão final e versão dos charts avaliados | — | Alta | P |
| HLM-03 | Criar `_helpers.tpl` global com helpers comuns (nome do registry, URL do GitLab, nome de namespace de projeto) | Helpers validados em pelo menos dois charts | HLM-01 | Alta | P |

---

### Épico 1 — Chart `tekton-registry`

Chart para o Docker Registry v2 interno (namespace `registry`).

| ID | História | Critério de aceite | Deps | Prio | Esforço |
|---|---|---|---|---|---|
| HLM-04 | Criar chart `tekton-registry` com Namespace, PVC, Deployment e Service NodePort | `helm install` sobe o registry; `curl http://<IP>:32000/v2/` retorna `{}` | HLM-01 | Alta | P |
| HLM-05 | Parametrizar `storage.size`, `nodePort`, `image.tag` e `image.repository` no values | `helm upgrade` com valores diferentes funciona sem erro | HLM-04 | Alta | P |
| HLM-06 | Adicionar liveness e readiness probes no Deployment | Pod entra em Ready apenas quando o registry responde na `/v2/` | HLM-04 | Média | P |
| HLM-07 | Adicionar `REGISTRY_STORAGE_DELETE_ENABLED: true` via values | Parâmetro configurável; default `true` para lab | HLM-04 | Baixa | P |

---

### Épico 2 — Chart `tekton-platform` — RBAC e Secrets

| ID | História | Critério de aceite | Deps | Prio | Esforço |
|---|---|---|---|---|---|
| HLM-08 | Criar o Namespace `ci` com labels via Helm | Namespace criado com `tekton.dev/role=platform` | HLM-01 | Alta | P |
| HLM-09 | Criar ServiceAccount `tekton-triggers-sa` + RoleBinding local + 2 ClusterRoleBindings (EL + create-pipelinerun) via Helm | Pod do EL sobe sem CrashLoopBackOff | HLM-08 | Alta | M |
| HLM-10 | Criar Secret `gitlab-webhook-secret` via Helm, com geração automática se não fornecido (`randAlphaNum 40`) | Secret existe em `ci`; valor recuperável com `helm get values` | HLM-08 | Alta | P |
| HLM-11 | Criar ConfigMap `cluster-resolver-config` e patch de feature flags via Helm (como Job pre-install ou via configmap direto) | Feature flags `enable-bundles-resolver` e `enable-cluster-resolver` = `true` | HLM-08 | Alta | M |

---

### Épico 3 — Chart `tekton-bundles`

Jobs Kubernetes que publicam os Task Bundles no registry interno.

| ID | História | Critério de aceite | Deps | Prio | Esforço |
|---|---|---|---|---|---|
| HLM-12 | Criar ConfigMaps com o YAML de cada Task (git-clone, maven-build, node-build, kaniko-build-push) | ConfigMaps existem no cluster, conteúdo é YAML válido | HLM-04 | Alta | M |
| HLM-13 | Criar Job template que monta o ConfigMap, verifica se bundle já existe (GET `/v2/<name>/tags/list`) e executa `tkn bundle push` se tag ausente | Job idempotente: rodar 2x não re-publica bundle existente | HLM-12 | Alta | G |
| HLM-14 | Usar Helm hook `pre-install, pre-upgrade` nos Jobs de bundle push | Jobs executam antes dos Pipelines serem aplicados (que dependem dos bundles) | HLM-13 | Alta | M |
| HLM-15 | Parametrizar tag de cada bundle no values (`bundles.gitClone.tag: v1`) e imagem base (`bundles.gitClone.image`) | Trocar tag = mudar uma linha no values + `helm upgrade` | HLM-13 | Alta | M |
| HLM-16 | Criar Story de rollout controlado: publicar bundle com nova tag e atualizar Pipeline em sequência via Helm | Documentação de como fazer upgrade de bundle sem downtime | HLM-15 | Média | M |

---

### Épico 4 — Chart `tekton-platform` — Pipelines e Triggers

| ID | História | Critério de aceite | Deps | Prio | Esforço |
|---|---|---|---|---|---|
| HLM-17 | Criar Pipelines por stack via loop `range .Values.platform.stacks` | `kubectl -n ci get pipeline` lista todos os pipelines definidos no values | HLM-09, HLM-15 | Alta | M |
| HLM-18 | Criar TriggerBinding e TriggerTemplate genéricos (sem stack específica hardcoded) | PipelineRun criado com namespace e pipeline corretos ao simular webhook | HLM-09 | Alta | M |
| HLM-19 | Criar Trigger com CEL gerado dinamicamente a partir de `platform.stacks` (filter + overlays) | Adicionar nova stack no values regenera o CEL correto | HLM-18 | Alta | G |
| HLM-20 | Criar EventListener e Service NodePort via Helm | Pod do EL `1/1 Running`; smoke test POST retorna HTTP 202 | HLM-19 | Alta | M |
| HLM-21 | Adicionar Helm test que valida o smoke test do EL (POST com token correto → 202) | `helm test tekton-platform` passa | HLM-20 | Média | M |

---

### Épico 5 — Chart `tekton-project` e Helmfile

| ID | História | Critério de aceite | Deps | Prio | Esforço |
|---|---|---|---|---|---|
| HLM-22 | Criar chart `tekton-project` que provisiona Namespace, Secret `gitlab-basic-auth` e ServiceAccount `pipeline-runner` | Namespace e recursos criados; SA tem secret referenciado | HLM-01 | Alta | M |
| HLM-23 | Parametrizar `project.name`, `project.gitlabPAT`, `project.gitlabURL`, `project.labels` no values | Dois projetos diferentes instalados com mesma chart sem conflito | HLM-22 | Alta | M |
| HLM-24 | Criar Helmfile (`helmfile.yaml`) com releases separadas por projeto (`proj-backend-payments`, `proj-frontend-portal`) | `helmfile sync` provisiona todos os namespaces de projeto | HLM-22 | Alta | M |
| HLM-25 | Adicionar suporte a múltiplos ambientes no Helmfile (`environments: lab, prod`) | `helmfile -e lab sync` vs `helmfile -e prod sync` usam values diferentes | HLM-24 | Média | M |
| HLM-26 | Documentar workflow de onboarding de nova app com Helm: adicionar bloco no Helmfile, commitar, aplicar | Tempo de onboarding documentado e testado | HLM-24 | Alta | P |

---

### Épico 6 — Tekton Dashboard (exposição NodePort)

| ID | História | Critério de aceite | Deps | Prio | Esforço |
|---|---|---|---|---|---|
| HLM-27 | Adicionar Service NodePort para o Dashboard no chart `tekton-platform` (ou chart separado `tekton-dashboard`) | Dashboard acessível em `http://<IP>:32097` | HLM-08 | Média | P |
| HLM-28 | Parametrizar `dashboard.nodePort` no values | Porta configurável sem editar template | HLM-27 | Baixa | P |

---

### Épico 7 — Segurança e boas práticas

| ID | História | Critério de aceite | Deps | Prio | Esforço |
|---|---|---|---|---|---|
| HLM-29 | Documentar abordagem de secrets no lab: `--set` via CLI, `values-local.yaml` no `.gitignore` | Arquivo `.gitignore` com `values-local.yaml`; README com instruções | HLM-01 | Alta | P |
| HLM-30 | Adicionar `securityContext` nos pods do Registry (runAsNonRoot, readOnlyRootFilesystem onde possível) | `kubectl get pod -n registry -o yaml` mostra securityContext configurado | HLM-04 | Média | M |
| HLM-31 | Adicionar ResourceRequirements (requests/limits) em todos os pods gerenciados pelos charts | Todos os containers têm `resources.requests` e `resources.limits` | HLM-04, HLM-13 | Média | M |
| HLM-32 | Avaliar Sealed Secrets para armazenar PATs no repositório de forma segura | ADR atualizado com decisão; se aprovado, implementar `SealedSecret` no tekton-project | HLM-22 | Média | G |

---

### Épico 8 — CI/CD dos próprios charts (meta)

| ID | História | Critério de aceite | Deps | Prio | Esforço |
|---|---|---|---|---|---|
| HLM-33 | Configurar GitLab CI para fazer `helm lint` e `helm template` em todo PR para os charts | Pipeline passa ou bloqueia merge com feedback claro | HLM-01 | Média | M |
| HLM-34 | Configurar GitLab CI para fazer `helm upgrade --install --dry-run` contra um cluster de teste | Pipeline valida que o chart aplica sem erro em cluster real | HLM-33 | Média | G |
| HLM-35 | Criar pipeline Tekton (usando a própria plataforma) para publicar novas versões dos charts | Irônico, mas útil: a plataforma valida a si mesma | HLM-34 | Baixa | GG |

---

## 6. Estrutura de values.yaml (schema central)

Exemplo completo do `values.yaml` do umbrella chart ou do `values-lab.yaml` central:

```yaml
# values-lab.yaml — valores específicos do laboratório

global:
  # Configurações de rede do lab
  gitlab:
    host: "192.168.0.13"
    port: 8929
    username: "root"
    # gitlabPAT: NUNCA commitar — passar via --set ou values-local.yaml

  cluster:
    serverIP: "192.168.56.110"

  registry:
    # URL interna ao cluster (DNS)
    internalURL: "registry.registry.svc.cluster.local:5000"
    # URL externa (NodePort, usada pelo tkn bundle push de fora do cluster)
    externalURL: "192.168.56.110:32000"

# ─── Chart: tekton-registry ───────────────────────────────────────────────────
registry:
  namespace: registry
  image:
    repository: registry
    tag: "2"
  storage:
    size: 20Gi
  service:
    nodePort: 32000
  config:
    deleteEnabled: true

# ─── Chart: tekton-platform ───────────────────────────────────────────────────
platform:
  namespace: ci

  eventListener:
    name: gitlab-listener
    nodePort: 32080

  workspace:
    size: 2Gi   # PVC por PipelineRun

  webhook:
    secretName: gitlab-webhook-secret
    # token: gerado automaticamente se omitido (randAlphaNum 40)

  # Stacks — cada item vira um Pipeline em ci e uma entrada no CEL
  stacks:
    - name: java
      prefix: "backend-"
      pipelineName: "java-app-pipeline"
    - name: node
      prefix: "frontend-"
      pipelineName: "node-app-pipeline"
    # Para adicionar Python: descomentar as linhas abaixo
    # - name: python
    #   prefix: "python-"
    #   pipelineName: "python-app-pipeline"

# ─── Chart: tekton-bundles ────────────────────────────────────────────────────
bundles:
  # Cada bundle vira um ConfigMap com o YAML da Task + um Job que faz o push
  gitClone:
    name: git-clone
    tag: v1
    image: "alpine/git:2.43.0"

  mavenBuild:
    name: maven-build
    tag: v1
    image: "maven:3.9-eclipse-temurin-17"

  nodeBuild:
    name: node-build
    tag: v1
    image: "node:20-alpine"
    defaultNodeVersion: "20"

  kaniko:
    name: kaniko-build-push
    tag: v1
    image: "gcr.io/kaniko-project/executor:v1.23.2"

# ─── Chart: tekton-dashboard ──────────────────────────────────────────────────
dashboard:
  service:
    nodePort: 32097

# ─── Chart: tekton-project (usado via Helmfile, um bloco por projeto) ─────────
# Exemplo de uso no Helmfile:
#
# releases:
#   - name: proj-backend-payments
#     chart: ./charts/tekton-project
#     values:
#       - values-lab.yaml
#     set:
#       - name: project.name
#         value: backend-payments
#       - name: project.gitlabPAT
#         value: {{ requiredEnv "PAT_BACKEND_PAYMENTS" }}
#
project:
  name: ""                  # obrigatório — nome do repo sem prefixo proj-
  gitlabPAT: ""             # obrigatório — PAT do GitLab (nunca commitar)
  labels:
    tekton.dev/project: "true"
```

---

## 7. Ordem de implementação

Sequência sugerida respeitando dependências técnicas:

```
Sprint 1 — Fundação
  HLM-01  Estrutura do repositório
  HLM-02  Avaliar charts comunitários do Tekton
  HLM-03  _helpers.tpl global
  HLM-29  Documentar abordagem de secrets

Sprint 2 — Registry
  HLM-04  Chart tekton-registry base
  HLM-05  Parametrização do registry
  HLM-06  Probes no registry
  HLM-07  Config STORAGE_DELETE_ENABLED

Sprint 3 — Platform: RBAC e base
  HLM-08  Namespace ci
  HLM-09  RBAC completo (SA + 3 bindings)
  HLM-10  Secret do webhook (geração automática)
  HLM-11  Feature flags + cluster-resolver-config
  HLM-27  Dashboard NodePort

Sprint 4 — Task Bundles
  HLM-12  ConfigMaps com YAMLs das Tasks
  HLM-13  Job template bundle push (idempotente)
  HLM-14  Helm hooks pre-install
  HLM-15  Parametrização de tags e imagens

Sprint 5 — Platform: Pipelines e Triggers
  HLM-17  Pipelines por stack (loop via values)
  HLM-18  TriggerBinding e TriggerTemplate
  HLM-19  CEL dinâmico por stacks
  HLM-20  EventListener + NodePort
  HLM-21  Helm test smoke

Sprint 6 — Projetos e Helmfile
  HLM-22  Chart tekton-project
  HLM-23  Parametrização do projeto
  HLM-24  Helmfile para múltiplos projetos
  HLM-26  Documentação de onboarding
  HLM-16  Guia de upgrade de bundles

Sprint 7 — Qualidade e segurança
  HLM-28  nodePort configurável do Dashboard
  HLM-30  securityContext nos pods
  HLM-31  ResourceRequirements
  HLM-25  Ambientes no Helmfile (lab/prod)
  HLM-32  Avaliar Sealed Secrets

Sprint 8 — CI/CD dos charts (meta)
  HLM-33  helm lint no GitLab CI
  HLM-34  helm upgrade --dry-run em cluster de teste
  HLM-35  Pipeline Tekton para publicar charts
```

### Resumo por prioridade

| Prioridade | IDs | Total |
|---|---|---|
| Alta | HLM-01 a 15, 17 a 24, 26, 29 | 26 histórias |
| Média | HLM-16, 21, 25, 27, 30, 31, 32, 33, 34 | 9 histórias |
| Baixa | HLM-07, 28, 35 | 3 histórias |

**Total: 38 histórias em 8 sprints.**

---

## Referências

- [Helm Best Practices](https://helm.sh/docs/chart_best_practices/)
- [Helmfile](https://github.com/helmfile/helmfile)
- [Tekton CLI image (tkn)](https://github.com/tektoncd/cli/pkgs/container/cli)
- [CDF Tekton Helm charts (comunitário)](https://github.com/cdfoundation/tekton-helm-chart)
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
- [External Secrets Operator](https://external-secrets.io/)
