> **⚠️ ARQUIVO SUPERSEDIDO** — O conteúdo deste arquivo foi consolidado e reorganizado em [tekton-multitenant.md](tekton-multitenant.md). Este arquivo é mantido apenas para referência histórica e pode ser removido.

---

# Refatoração Multi-tenant e Playbook de Novas Apps — Tekton no k3s

Documentação da evolução da plataforma Tekton para **multi-tenant com múltiplos stacks**, incluindo o **playbook detalhado** para adicionar novas aplicações — passo a passo, com explicação de cada decisão.

> Continuação natural do [tekton-lab-setup.md](tekton-lab-setup.md). Assume que a infraestrutura básica (Tekton + Registry + GitLab + Task Bundles do backend) está funcionando.

---

## Sumário

1. [Motivação e visão da arquitetura final](#1-motivação-e-visão-da-arquitetura-final)
2. [Convenções de nomeação adotadas](#2-convenções-de-nomeação-adotadas)
3. [Componentes centralizados no ci](#3-componentes-centralizados-no-ci)
4. [Como o EventListener roteia o webhook](#4-como-o-eventlistener-roteia-o-webhook)
5. [Fluxo end-to-end explicado passo a passo](#5-fluxo-end-to-end-explicado-passo-a-passo)
6. [Etapa 1 — Habilitar cluster resolver](#6-etapa-1--habilitar-cluster-resolver)
7. [Etapa 2 — Criar o EventListener multi-tenant no ci](#7-etapa-2--criar-o-eventlistener-multi-tenant-no-ci)
8. [Etapa 3 — Task Bundles compartilhados](#8-etapa-3--task-bundles-compartilhados)
9. [Etapa 4 — Pipelines por stack](#9-etapa-4--pipelines-por-stack)
10. [🎯 PLAYBOOK: Adicionar uma nova aplicação (do zero)](#10--playbook-adicionar-uma-nova-aplicação-do-zero)
11. [Prompts para diagramas com Gemini](#11-prompts-para-diagramas-com-gemini)
12. [Troubleshooting acumulado](#12-troubleshooting-acumulado)

---

## 1. Motivação e visão da arquitetura final

### Antes (single-tenant)

Todo mundo compartilhando o namespace `ci`:
- Pipeline `java-app-pipeline`
- PipelineRuns de qualquer projeto
- Secrets misturados
- Sem isolamento

### Agora (multi-tenant com múltiplos stacks)

Separação clara de responsabilidades:

- **`ci`** = a **plataforma**. Concentra: Pipelines (um por stack), Trigger, EventListener, RBAC de despacho
- **`proj-<repo>`** = **cada aplicação**. Tem seu SA, secret git, PipelineRuns
- **Roteamento por prefixo**: `backend-*` → Pipeline Java, `frontend-*` → Pipeline Node

### Ganho prático

Adicionar uma nova aplicação Java ou Node agora é o mesmo procedimento repetível de ~5 comandos. Não mexe em nada da plataforma.

---

## 2. Convenções de nomeação adotadas

Convenções fixas — segui-las evita 90% dos problemas:

| Elemento | Padrão | Exemplo |
|---|---|---|
| **Repo GitLab (backend Java)** | `backend-<nome>` | `backend-java-app` |
| **Repo GitLab (frontend Node)** | `frontend-<nome>` | `frontend-angular` |
| **Namespace do projeto** | `proj-<nome-do-repo>` | `proj-frontend-angular` |
| **ServiceAccount de execução** | `pipeline-runner` (fixo, por namespace) | — |
| **Secret Git basic-auth** | `gitlab-basic-auth` (fixo, por namespace) | — |
| **Pipeline no ci (Java)** | `java-app-pipeline` | — |
| **Pipeline no ci (Node)** | `node-app-pipeline` | — |
| **Imagem no registry** | `apps/<nome-do-repo>:<sha>` | `apps/frontend-angular:82a57d1...` |

**Por que prefixo no repo:**
- O CEL do Trigger olha `body.project.name` e usa o prefixo pra decidir qual Pipeline aplicar
- Se um dia entrar Python, basta convenção `python-*` → `python-app-pipeline`
- Sem prefixo, teria que manter um mapa manual em algum lugar

---

## 3. Componentes centralizados no ci

O namespace `ci` funciona como "produto plataforma". Ele contém:

### 3.1. Pipelines por stack

```
kubectl -n ci get pipeline
```
Retorna:
```
NAME                 AGE
java-app-pipeline    ...
node-app-pipeline    ...
```

Cada Pipeline referencia Task Bundles via `resolver: bundles`, do registry interno.

### 3.2. EventListener central

```
kubectl -n ci get eventlistener
```
Retorna:
```
NAME              ADDRESS                                             READY
gitlab-listener   http://el-gitlab-listener.ci.svc.cluster.local:8080  True
```

Exposto externamente via NodePort 32080. **Todos** os webhooks do GitLab apontam para ele.

### 3.3. RBAC para criar PipelineRuns em outros namespaces

A `ServiceAccount tekton-triggers-sa` do `ci` precisa de:
- `RoleBinding` local (padrão do Triggers)
- `ClusterRoleBinding` para `tekton-triggers-eventlistener-clusterroles`
- `ClusterRoleBinding` customizado para **criar** `pipelineruns` em qualquer namespace

### 3.4. Secret do webhook

Um único secret compartilhado por todos os projetos:
```
gitlab-webhook-secret (namespace: ci)
```

Todos os webhooks dos repos usam esse mesmo token.

---

## 4. Como o EventListener roteia o webhook

Aqui está o coração da arquitetura — o momento onde o CEL calcula o roteamento:

### 4.1. GitLab manda o payload

```json
{
  "object_kind": "push",
  "checkout_sha": "82a57d1...",
  "project": {
    "name": "frontend-angular",
    "git_http_url": "http://192.168.0.13:8929/root/frontend-angular.git"
  }
}
```

### 4.2. Interceptor `gitlab` valida o token

Header `X-Gitlab-Token` é comparado com o valor do secret. Se não bater, evento rejeitado.

### 4.3. Interceptor `cel` decide o roteamento

Três cálculos:

```yaml
- key: target-namespace
  expression: "'proj-' + body.project.name"
  # → "proj-frontend-angular"

- key: repo-name
  expression: "body.project.name"
  # → "frontend-angular"

- key: pipeline-name
  expression: |
    body.project.name.startsWith('frontend-') ? 'node-app-pipeline' :
    body.project.name.startsWith('backend-')  ? 'java-app-pipeline' :
    'UNKNOWN'
  # → "node-app-pipeline"
```

E um filtro (se não bater o prefixo, evento silenciosamente descartado):

```yaml
- name: filter
  value: >-
    body.project.name.startsWith('frontend-') ||
    body.project.name.startsWith('backend-')
```

### 4.4. TriggerBinding empacota os params

Junta os overlays CEL com dados do payload:

```yaml
- name: repo-url         → body.repository.git_http_url
- name: revision         → body.checkout_sha
- name: short-sha        → body.checkout_sha
- name: target-namespace → extensions.target-namespace
- name: repo-name        → extensions.repo-name
- name: pipeline-name    → extensions.pipeline-name
```

### 4.5. TriggerTemplate cria o PipelineRun

Usa os params pra renderizar dinamicamente:
- `metadata.namespace: proj-frontend-angular`
- `spec.taskRunTemplate.serviceAccountName: pipeline-runner`
- `spec.pipelineRef.name: node-app-pipeline` (via cluster resolver, mora no `ci`)
- `spec.params.image: registry.registry.svc.cluster.local:5000/apps/frontend-angular:82a57d1...`

---

## 5. Fluxo end-to-end explicado passo a passo

```
Developer  ──git push──>  GitLab  ──HTTP POST──>  EventListener (ci)
                                                       │
                                          ┌────────────┴────────────┐
                                          │ gitlab: valida X-Token  │
                                          │ cel: calcula overlays   │
                                          │ cel: aplica filter      │
                                          └────────────┬────────────┘
                                                       │
                                          ┌────────────┴────────────┐
                                          │ TriggerBinding empacota │
                                          │ TriggerTemplate renderiza│
                                          └────────────┬────────────┘
                                                       │ create pipelinerun
                                                       ▼
                                     PipelineRun em proj-frontend-angular
                                        │
                                        │ pipelineRef via cluster resolver
                                        ▼
                                Pipeline java-app-pipeline
                                ou node-app-pipeline (em ci)
                                        │
                                        │ taskRef via bundles resolver
                                        ▼
                     Task Bundles no registry (git-clone, maven|node, kaniko)
                                        │
                                        ▼
                     Tasks executam com SA pipeline-runner
                     (usando gitlab-basic-auth do namespace do projeto)
                                        │
                                        ▼
                     Imagem final publicada no registry:
                     apps/<repo-name>:<sha>
```

---

## 6. Etapa 1 — Habilitar cluster resolver

Sem isso, PipelineRuns em `proj-*` não conseguem enxergar Pipelines em `ci`.

```bash
# Habilita a feature
kubectl -n tekton-pipelines patch cm feature-flags \
  --type merge -p '{"data":{"enable-cluster-resolver":"true"}}'

# Configura quais namespaces o resolver pode acessar
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-resolver-config
  namespace: tekton-pipelines-resolvers
data:
  default-namespace: "ci"
  allowed-namespaces: "ci"
EOF
```

**Explicação:** `allowed-namespaces: "ci"` significa que qualquer PipelineRun em qualquer namespace pode buscar Pipelines/Tasks **apenas** em `ci`. Segurança por design.

Validar:
```bash
kubectl -n tekton-pipelines get cm feature-flags \
  -o jsonpath='{.data.enable-cluster-resolver}'
# esperado: true
```

---

## 7. Etapa 2 — Criar o EventListener multi-tenant no ci

### 7.1. RBAC para criar PipelineRuns cross-namespace

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tekton-triggers-create-pipelinerun
rules:
- apiGroups: ["tekton.dev"]
  resources: ["pipelineruns"]
  verbs: ["create", "get", "list", "watch"]
- apiGroups: [""]
  resources: ["serviceaccounts"]
  verbs: ["impersonate"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tekton-triggers-sa-create-pipelinerun
subjects:
- kind: ServiceAccount
  name: tekton-triggers-sa
  namespace: ci
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tekton-triggers-create-pipelinerun
EOF
```

### 7.2. Trigger com dois interceptors (gitlab + cel)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: triggers.tekton.dev/v1beta1
kind: Trigger
metadata:
  name: gitlab-push-trigger
  namespace: ci
spec:
  serviceAccountName: tekton-triggers-sa
  interceptors:
  - ref:
      name: "gitlab"
    params:
    - name: secretRef
      value:
        secretName: gitlab-webhook-secret
        secretKey: secretToken
    - name: eventTypes
      value: ["Push Hook"]
  - ref:
      name: "cel"
    params:
    - name: filter
      value: >-
        body.project.name.startsWith('frontend-') ||
        body.project.name.startsWith('backend-')
    - name: overlays
      value:
      - key: target-namespace
        expression: "'proj-' + body.project.name"
      - key: repo-name
        expression: "body.project.name"
      - key: pipeline-name
        expression: |
          body.project.name.startsWith('frontend-') ? 'node-app-pipeline' :
          body.project.name.startsWith('backend-')  ? 'java-app-pipeline' :
          'UNKNOWN'
  bindings:
  - ref: gitlab-push-binding
  template:
    ref: app-template
EOF
```

### 7.3. TriggerBinding

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerBinding
metadata:
  name: gitlab-push-binding
  namespace: ci
spec:
  params:
  - name: repo-url
    value: $(body.repository.git_http_url)
  - name: revision
    value: $(body.checkout_sha)
  - name: short-sha
    value: $(body.checkout_sha)
  - name: target-namespace
    value: $(extensions.target-namespace)
  - name: repo-name
    value: $(extensions.repo-name)
  - name: pipeline-name
    value: $(extensions.pipeline-name)
EOF
```

### 7.4. TriggerTemplate genérico (app-template)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: app-template
  namespace: ci
spec:
  params:
  - name: repo-url
  - name: revision
  - name: short-sha
  - name: target-namespace
  - name: repo-name
  - name: pipeline-name
  resourcetemplates:
  - apiVersion: tekton.dev/v1
    kind: PipelineRun
    metadata:
      generateName: $(tt.params.repo-name)-run-
      namespace: $(tt.params.target-namespace)
    spec:
      taskRunTemplate:
        serviceAccountName: pipeline-runner
      pipelineRef:
        resolver: cluster
        params:
        - name: kind
          value: pipeline
        - name: name
          value: $(tt.params.pipeline-name)
        - name: namespace
          value: ci
      params:
      - name: repo-url
        value: $(tt.params.repo-url)
      - name: revision
        value: $(tt.params.revision)
      - name: image
        value: registry.registry.svc.cluster.local:5000/apps/$(tt.params.repo-name):$(tt.params.short-sha)
      workspaces:
      - name: shared
        volumeClaimTemplate:
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 2Gi
EOF
```

### 7.5. EventListener e Service NodePort

Se ainda não estiver criado:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: gitlab-listener
  namespace: ci
spec:
  serviceAccountName: tekton-triggers-sa
  triggers:
  - triggerRef: gitlab-push-trigger
---
apiVersion: v1
kind: Service
metadata:
  name: el-gitlab-listener-np
  namespace: ci
spec:
  type: NodePort
  selector:
    eventlistener: gitlab-listener
  ports:
  - port: 8080
    targetPort: 8080
    nodePort: 32080
EOF
```

Após qualquer mudança no Trigger/Binding/Template, reinicia o pod do EL:

```bash
kubectl -n ci delete pod -l eventlistener=gitlab-listener
```

---

## 8. Etapa 3 — Task Bundles compartilhados

Os Task Bundles moram no registry e são reutilizados por qualquer Pipeline. Isso é o que torna adicionar apps trivial: novas apps reaproveitam o mesmo `git-clone` e `kaniko`.

### 8.1. Task Bundles disponíveis

```
registry.registry.svc.cluster.local:5000/tekton/git-clone:v1
registry.registry.svc.cluster.local:5000/tekton/maven-build:v1
registry.registry.svc.cluster.local:5000/tekton/node-build:v1
registry.registry.svc.cluster.local:5000/tekton/kaniko-build-push:v1
```

Confirma:
```bash
curl -s http://192.168.56.110:32000/v2/_catalog
```

### 8.2. Task node-build (versão que funcionou)

Vale registrar a versão final que passou nos testes:

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: node-build
spec:
  description: Instala dependências e compila uma aplicação Node.js/Angular.
  params:
  - name: node-version
    type: string
    default: "20"
  - name: build-command
    type: string
    default: "npm run build"
  - name: install-command
    type: string
    default: "npm install"     # ← "npm install", não "npm ci" (evita exigir package-lock.json)
  workspaces:
  - name: source
  steps:
  - name: install
    image: node:$(params.node-version)-alpine
    workingDir: $(workspaces.source.path)
    script: |
      #!/bin/sh
      set -eu
      echo "Executando: $(params.install-command)"
      $(params.install-command)
  - name: build
    image: node:$(params.node-version)-alpine
    workingDir: $(workspaces.source.path)
    script: |
      #!/bin/sh
      set -eu
      echo "Executando: $(params.build-command)"
      $(params.build-command)
      ls -lh dist/ 2>/dev/null || echo "dist nao encontrado"
```

Publicar:
```bash
tkn bundle push 192.168.56.110:32000/tekton/node-build:v1 -f tasks/node-build.yaml
```

**Lições aprendidas com essa task:**
- Evitar `$(comando)` do shell dentro dos scripts — Tekton usa `$(...)` como sintaxe própria e conflita
- `npm ci` exige `package-lock.json` no repo. Se você criou o `package.json` manualmente sem gerar o lock file antes, use `npm install`

---

## 9. Etapa 4 — Pipelines por stack

Dois Pipelines diferentes no `ci`, cada um reaproveitando Task Bundles.

### 9.1. java-app-pipeline

Tasks: `git-clone → maven-build → kaniko-build-push`

### 9.2. node-app-pipeline

Tasks: `git-clone → node-build → kaniko-build-push`

Detalhe importante do Pipeline Node — passar o `install-command` explicitamente pra evitar `npm ci` do default:

```yaml
- name: build
  runAfter: [clone]
  taskRef:
    resolver: bundles
    params:
    - { name: bundle, value: registry.registry.svc.cluster.local:5000/tekton/node-build:v1 }
    - { name: name, value: node-build }
    - { name: kind, value: task }
  params:
  - name: install-command
    value: "npm install"        # ← força o comando permissivo
  workspaces:
  - name: source
    workspace: shared
```

Ver os dois Pipelines convivendo:
```bash
kubectl -n ci get pipeline
```

---

## 10. 🎯 PLAYBOOK: Adicionar uma nova aplicação (do zero)

Esta é a seção que você quer dominar. Todo processo em **6 passos claros**, com o **porquê** de cada um.

### Cenário

Você quer adicionar uma nova aplicação — pode ser Java ou Node. Vou usar `backend-payments` (Java) como exemplo, mas o processo é idêntico pra Node (só troca o prefixo).

---

### Passo 1 — Escolher o nome do repo obedecendo a convenção

**Regra:** o nome do repo no GitLab precisa começar com `backend-` (Java) ou `frontend-` (Node).

| Se o app é… | Prefixo | Exemplo |
|---|---|---|
| Java/Maven | `backend-` | `backend-payments`, `backend-orders` |
| Node/Angular/React | `frontend-` | `frontend-portal`, `frontend-admin` |

**Por quê:** o CEL do Trigger central lê o `body.project.name` do webhook e decide qual Pipeline aplicar pelo prefixo. Sem prefixo, o `filter` do CEL descarta o evento e nada acontece.

---

### Passo 2 — Criar o projeto no GitLab

Na UI do GitLab:

1. Canto superior direito **+ → New project → Create blank project**
2. **Project name:** `backend-payments`
3. **Visibility Level:** `Internal` (permite auth com PAT sem pedir MFA/email)
4. **Initialize repository with a README:** desmarcar
5. **Create project**

**Anote a URL do repo** que aparece no topo, tipicamente `http://192.168.0.13:8929/root/backend-payments.git`.

---

### Passo 3 — Gerar um PAT dedicado pro projeto

O Personal Access Token é a **credencial que a Task `git-clone` usará** pra baixar o código do repo.

1. Avatar (canto superior direito) → **Preferences**
2. Menu lateral: **Access tokens** → **Add new token**
3. **Name:** `tekton-proj-backend-payments` (bom pra auditoria: você sabe pra que serve olhando o nome)
4. **Expiration:** deixar em branco pra lab
5. **Scopes:** marcar `read_repository`
6. **Create personal access token**
7. **⚠️ Copie o valor imediatamente** — ele só é exibido uma vez. Se perder, tem que criar outro

**Por quê PAT dedicado por projeto:** se um dia esse PAT vazar, você revoga só o daquele projeto sem afetar os outros. Sem PAT dedicado, você teria que revogar um secret que todos usam.

---

### Passo 4 — Provisionar o namespace do projeto no cluster

Aqui é onde a "conta" pro projeto é criada no Kubernetes. Substitua `<PAT>` pelo valor real.

```bash
# 1. Namespace com labels (labels ajudam em queries futuras: kubectl get ns -l app=payments)
kubectl create ns proj-backend-payments
kubectl label ns proj-backend-payments \
  tekton.dev/project=true \
  app=backend-payments

# 2. Secret basic-auth com o PAT
kubectl -n proj-backend-payments create secret generic gitlab-basic-auth \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=root \
  --from-literal=password='<PAT>'

# 3. Anotar o secret com a URL do GitLab
#    (o Tekton usa essa anotação pra saber "quando clonar dessa URL, use esse secret")
kubectl -n proj-backend-payments annotate secret gitlab-basic-auth \
  tekton.dev/git-0=http://192.168.0.13:8929

# 4. ServiceAccount pipeline-runner com o secret anexado
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pipeline-runner
  namespace: proj-backend-payments
secrets:
- name: gitlab-basic-auth
EOF
```

**Validação:**
```bash
kubectl -n proj-backend-payments get sa,secret
```
Deve mostrar `pipeline-runner`, `default`, `gitlab-basic-auth`.

**Por que os nomes são fixos (`pipeline-runner`, `gitlab-basic-auth`):** o `TriggerTemplate` do `ci` referencia esses nomes literalmente. Se você mudar o nome, o `PipelineRun` gerado pelo webhook não vai encontrar a SA e vai usar `default` — que não tem o secret anexado → clone falha.

---

### Passo 5 — Cadastrar o webhook do repo no GitLab

Aqui você conecta o GitLab ao EventListener central.

**Pegar o token do webhook** (é o mesmo pra todos os projetos):
```bash
kubectl -n ci get secret gitlab-webhook-secret -o jsonpath='{.data.secretToken}' | base64 -d
echo
```
Copie esse valor.

Na UI do GitLab, no projeto `backend-payments`:

1. **Settings → Webhooks → Add new webhook**
2. **URL:** `http://192.168.56.110:32080` (endereço do EventListener central)
3. **Secret Token:** cole o valor obtido acima
4. **Trigger:** ✓ Push events
5. **Enable SSL verification:** ☐ **desmarcar** (o EL é HTTP)
6. **Add webhook**

**Teste:** na linha do webhook cadastrado, botão **Test → Push events**. Resposta esperada: `Hook executed successfully: HTTP 202`.

**Por que a URL é sempre a mesma:** o EventListener em `ci` recebe **todos** os webhooks e roteia internamente. Você não precisa criar um EL por projeto. Isso é o coração da plataforma multi-tenant.

**Por que Enable SSL verification desmarcado:** o EL responde HTTP puro no NodePort. Em produção, você colocaria um Ingress com TLS na frente.

---

### Passo 6 — Fazer push do código (com os arquivos mínimos)

Última etapa: colocar código no repo, com **`Dockerfile` na raiz**. Sem o Dockerfile, o Kaniko não tem o que buildar.

#### Se for Java (backend-*)

Estrutura mínima:
```
backend-payments/
├── pom.xml           # Maven descriptor
├── Dockerfile        # multi-stage: mvn build (interno) + jre runtime
└── src/main/java/... # código
```

Dockerfile (usa o JAR já gerado pelo `mvn package` da task `maven-build`):
```dockerfile
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY target/*.jar app.jar
ENTRYPOINT ["java", "-jar", "app.jar"]
```

#### Se for Node/Angular (frontend-*)

Estrutura mínima:
```
frontend-portal/
├── package.json
├── angular.json (ou vite.config.js, next.config.js…)
├── tsconfig.json
├── src/
├── nginx.conf         # se serve com nginx
└── Dockerfile         # multi-stage: node build + nginx serve
```

Dockerfile:
```dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
RUN npm run build

FROM nginx:1.27-alpine
COPY --from=builder /app/dist/frontend-portal/ /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

#### Push:
```bash
cd backend-payments
git init
git add .
git commit -m "Initial commit"
git remote add origin http://192.168.0.13:8929/root/backend-payments.git
git push -u origin main
```

O push dispara o webhook automaticamente. Pipeline começa a rodar.

---

### Como acompanhar a execução

Três terminais (opcional, mas didático):

**Terminal 1 — log do EL** (ver o CEL calculando o roteamento em tempo real):
```bash
kubectl -n ci logs -l eventlistener=gitlab-listener -f --timestamps
```

**Terminal 2 — status do run**:
```bash
kubectl -n proj-backend-payments get pipelinerun -w
```

**Terminal 3 — log do pipeline** (rodar depois que o run aparecer):
```bash
tkn pipelinerun logs -f -n proj-backend-payments --last
```

Ao final, verificar a imagem no registry:
```bash
curl -s http://192.168.56.110:32000/v2/apps/backend-payments/tags/list
```

---

### 📋 Checklist rápido de adicionar app

Quando você já dominar, é só isso:

```
[ ] Repo no GitLab com prefixo backend- ou frontend-
[ ] PAT gerado no GitLab
[ ] Namespace proj-<repo> criado
[ ] Secret gitlab-basic-auth com PAT + annotation
[ ] ServiceAccount pipeline-runner com secret anexado
[ ] Webhook cadastrado no GitLab (URL + token)
[ ] Dockerfile na raiz do repo
[ ] git push
```

Em torno de 5 minutos por app.

---

## 11. Prompts para diagramas com Gemini

### Prompt 1 — Arquitetura multi-tenant final

```
Create a professional Kubernetes multi-tenant CI/CD architecture diagram:

Central-top: large rectangle "namespace: ci (Platform)" containing:
- "Pipeline: java-app-pipeline"
- "Pipeline: node-app-pipeline"
- "EventListener: gitlab-listener (NodePort 32080)"
- "Trigger with gitlab + cel interceptors"
- "TriggerBinding + TriggerTemplate (app-template)"
- "ServiceAccount: tekton-triggers-sa"
- "Secret: gitlab-webhook-secret"

Below, three tenant namespaces side by side:
- "proj-backend-java-app" (Java)
- "proj-frontend-angular" (Node)
- "proj-backend-payments (future)" (Java)

Each tenant contains:
- "ServiceAccount: pipeline-runner"
- "Secret: gitlab-basic-auth"
- "PipelineRuns"

Arrows:
- Downward arrow from ci to each tenant labeled 
  "CEL routes based on repo prefix (frontend-*, backend-*)"
- Arrow from each PipelineRun back to ci labeled 
  "resolver: cluster (fetches Pipeline)"
- Small box on the right: "Registry (Task Bundles + Images)" 
  with arrow from Pipelines labeled "resolver: bundles"

Style: clean cloud-native architecture diagram, blue and green palette, 
Kubernetes-themed, English labels, white background, professional.
```

### Prompt 2 — Sequência do CEL routing

```
Create a horizontal sequence diagram showing CEL-based routing decisions:

Step 1: GitLab webhook arrives with payload:
  {"project": {"name": "frontend-angular"}, "checkout_sha": "abc..."}

Step 2: gitlab interceptor validates X-Gitlab-Token → success

Step 3: cel interceptor filter:
  body.project.name.startsWith('frontend-') || 
  body.project.name.startsWith('backend-')
  → passes filter

Step 4: cel overlays compute:
  target-namespace = "proj-" + "frontend-angular" = "proj-frontend-angular"
  pipeline-name = "node-app-pipeline" (starts with frontend-)
  repo-name = "frontend-angular"

Step 5: TriggerBinding + TriggerTemplate render PipelineRun with:
  namespace: proj-frontend-angular
  pipelineRef.name: node-app-pipeline
  pipelineRef.resolver: cluster
  serviceAccountName: pipeline-runner

Step 6: PipelineRun created and starts running

Highlight the decision points with question marks and arrows.
Style: modern sequence diagram, purple and orange palette, 
English labels, white background, professional DevOps documentation.
```

### Prompt 3 — Playbook adicionar app (fluxograma)

```
Create a 6-step vertical checklist-style flowchart for onboarding a new 
application to the Tekton multi-tenant platform:

Step 1: "Name your repo with prefix (backend-* or frontend-*)"
        Icon: Git branch
Step 2: "Create GitLab project (Internal visibility)"
        Icon: GitLab logo
Step 3: "Generate a dedicated PAT (read_repository scope)"
        Icon: key
Step 4: "Provision namespace: create ns, secret, ServiceAccount"
        Icon: Kubernetes namespace
        Sub-items:
          - kubectl create ns proj-<repo>
          - kubectl create secret basic-auth + annotate
          - kubectl apply -f serviceaccount.yaml
Step 5: "Configure GitLab webhook to EventListener 
         (URL: http://192.168.56.110:32080)"
        Icon: webhook / connection
Step 6: "Push code with Dockerfile at repo root"
        Icon: rocket

End with a green checkmark: "Pipeline runs automatically on every push"

Style: modern checklist infographic, green and blue palette, 
clean icons, English labels, white background, 
suitable for onboarding documentation.
```

---

## 12. Troubleshooting acumulado

Todos os problemas enfrentados durante a construção do multi-tenant.

### 12.1. `cannot use generate name with apply`

**Sintoma:** ao rodar `kubectl apply` num PipelineRun com `generateName`.

**Causa:** `apply` precisa saber o nome exato do recurso.

**Solução:** usar `kubectl create` em vez de `apply`. Para todos os outros recursos (Trigger, TriggerBinding, TriggerTemplate, EventListener, RBAC) que têm `name` fixo, `apply` funciona normalmente.

---

### 12.2. PipelineRun falha no clone: "could not read Username"

**Sintoma:**
```
fatal: could not read Username for 'http://192.168.0.13:8929'
```

**Causas possíveis (em ordem de probabilidade):**

1. **PipelineRun está usando SA `default`** (que não tem o secret git).
   ```bash
   tkn pipelinerun describe <name> -n <ns> | grep "Service Account"
   ```
   Se aparecer `default`, o `TriggerTemplate` está sem `spec.taskRunTemplate.serviceAccountName: pipeline-runner`.

2. **Na API `v1`, a SA vai em `spec.taskRunTemplate.serviceAccountName`** — não em `spec.serviceAccountName` (que era da `v1beta1`).

3. **Anotação do secret com URL errada:**
   ```bash
   kubectl -n <ns> get secret gitlab-basic-auth -o yaml | grep -A2 annotations
   ```
   Deve mostrar `tekton.dev/git-0: http://192.168.0.13:8929`.

4. **PAT expirado ou com scope errado** (precisa `read_repository`).

---

### 12.3. EL retorna 202 mas PipelineRun não é criado

**Diagnóstico:**
```bash
kubectl -n ci logs -l eventlistener=gitlab-listener --tail=50
```

**Causas:**
- **`forbidden` no log:** falta o `ClusterRoleBinding` que dá permissão pra criar PipelineRuns em outros namespaces (etapa 7.1)
- **Filter CEL rejeitou:** repo não segue prefixo. Renomear no GitLab ou ajustar filter

---

### 12.4. Cluster resolver retorna `ResolutionFailed`

**Causas:**
- Feature flag desligada (etapa 6)
- `cluster-resolver-config` sem o namespace de origem em `allowed-namespaces`
- Pipeline não existe em `ci` com o nome esperado (comum quando o CEL calcula `pipeline-name: UNKNOWN`)

Diagnóstico:
```bash
kubectl get pipelinerun <name> -n <ns> -o yaml | grep -A5 status
```

---

### 12.5. `tkn bundle push` falha com "not YAML or JSON parseable"

**Sintoma:**
```
Error: found a spec that isn't YAML or JSON parseable
```

**Causa:** Task tem sintaxe `$(comando)` no shell script (ex: `$(node --version)`). Tekton usa `$(...)` como sintaxe própria e conflita com o parser YAML.

**Solução:** remover essas linhas do script. Se você precisa mesmo do valor, usar arquivo temporário ou variável de ambiente do container.

**❌ Ruim:**
```yaml
script: |
  echo "Version: $(node --version)"
```

**✅ Bom:**
```yaml
script: |
  node --version > /tmp/nv
  echo "Version:"
  cat /tmp/nv
```

---

### 12.6. `npm ci` falha com "requires package-lock.json"

**Sintoma:**
```
The `npm ci` command can only install with an existing package-lock.json
```

**Causa:** repo não tem `package-lock.json` (comum quando o `package.json` foi criado manualmente).

**Solução:** trocar `npm ci` por `npm install`. Na Task `node-build`:
```yaml
- name: install-command
  value: "npm install"
```

Ou gerar o lock file local antes do push:
```bash
npm install
git add package-lock.json
git commit -m "Add lock file"
git push
```

---

### 12.7. Task `node-build` publicada com script quebrado

**Sintoma no log:**
```
[install] Node: 12(node --version)
[install] npm:  12(npm --version)
```

Repare que `$(node --version)` virou lixo (`12` seguido do parênteses literal). Isso é a expansão incorreta.

**Causa:** o "escape" `$$(comando)` não funciona como esperado no field `script` da Task.

**Solução:** simplesmente remover essas linhas de debug. Elas não valem o esforço.

---

### 12.8. CEL não gera `extensions`

**Sintoma:** TriggerBinding recebe param vazio, PipelineRun tenta ser criado em namespace `""`.

**Causa:** interceptor `cel` não está registrado no cluster.

**Diagnóstico:**
```bash
kubectl get clusterinterceptors | grep cel
```

**Solução:** reaplicar interceptors:
```bash
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
```

---

### 12.9. Webhook do GitLab: "Invalid url given"

**Causa:** GitLab bloqueia webhooks para redes privadas por default (proteção SSRF).

**Solução:** **Admin Area → Settings → Network → Outbound requests** → marcar "Allow requests to the local network from webhooks and integrations" → Save.

---

### 12.10. Webhook: "Connection refused"

**Causa:** container do GitLab está em rede Docker isolada, não rota pra 192.168.56.0/24.

**Solução:** trocar `docker-compose.yml` pra `network_mode: host` e remover `ports:`, mantendo `nginx['listen_port'] = 8929` no `external_url`.

---

## Referências

- [Tekton Cluster Resolver](https://tekton.dev/docs/pipelines/cluster-resolver/)
- [Tekton CEL Interceptor](https://tekton.dev/docs/triggers/cel_expressions/)
- [Tekton Auth for Git](https://tekton.dev/docs/pipelines/auth/#configuring-basic-auth-authentication-for-git)
- [GitLab Webhooks](https://docs.gitlab.com/ee/user/project/integrations/webhooks.html)
- [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
