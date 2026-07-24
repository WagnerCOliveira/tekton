> **⚠️ ARQUIVO SUPERSEDIDO** — O conteúdo deste arquivo foi consolidado e reorganizado em [tekton-multitenant.md](tekton-multitenant.md). Este arquivo é mantido apenas para referência histórica e pode ser removido.

---

# Refatoração para o Padrão B — Pipelines multi-tenant no Tekton

Documentação da migração da arquitetura Tekton de **single-tenant** (tudo em `ci`) para **multi-tenant** (Pipelines em `ci`, PipelineRuns isolados por projeto).

> Este documento é a continuação natural do [tekton-lab-setup.md](tekton-lab-setup.md). Assume que a infraestrutura básica (Tekton + Registry + GitLab + Task Bundles) já está funcionando.

---

## Sumário

1. [Motivação e decisão de arquitetura](#1-motivação-e-decisão-de-arquitetura)
2. [Análise dos três padrões possíveis](#2-análise-dos-três-padrões-possíveis)
3. [Arquitetura final escolhida](#3-arquitetura-final-escolhida)
4. [Etapa 1.1 — Habilitar o cluster resolver](#4-etapa-11--habilitar-o-cluster-resolver)
5. [Etapa 1.2 — Criar namespace do projeto](#5-etapa-12--criar-namespace-do-projeto)
6. [Etapa 1.3 — RBAC e secrets no namespace do projeto](#6-etapa-13--rbac-e-secrets-no-namespace-do-projeto)
7. [Etapa 1.4 — EventListener multi-namespace com CEL](#7-etapa-14--eventlistener-multi-namespace-com-cel)
8. [Etapa 1.5 — Validação end-to-end](#8-etapa-15--validação-end-to-end)
9. [Como adicionar um novo projeto](#9-como-adicionar-um-novo-projeto)
10. [Prompts para diagramas com Gemini](#10-prompts-para-diagramas-com-gemini)
11. [Troubleshooting](#11-troubleshooting)
12. [Próximos passos do roadmap](#12-próximos-passos-do-roadmap)

---

## 1. Motivação e decisão de arquitetura

### Problema com a arquitetura anterior (single-tenant)

Na configuração original, **tudo** ficava no namespace `ci`:
- Pipeline `java-app-pipeline`
- Trigger, TriggerBinding, TriggerTemplate, EventListener
- Secrets (webhook, basic-auth git)
- PipelineRuns de qualquer projeto

Isso funciona pra um único projeto, mas não escala. Se um segundo time entrar no cluster:
- Vai enxergar todos os secrets do outro time
- Vai compartilhar as mesmas cotas de recurso
- Não dá pra aplicar policies distintas por projeto
- Auditoria vira uma sopa

### O que muda no padrão B

- **`ci`** vira o **namespace concentrador** — só a definição do Pipeline e o EventListener central moram lá
- **Cada projeto** ganha seu próprio namespace `proj-<repo>` com secrets, SA e PipelineRuns isolados
- **O EventListener** roteia dinamicamente baseado no nome do repo

---

## 2. Análise dos três padrões possíveis

### Padrão A — Todos os PipelineRuns rodam em `ci` (o original)

- ✅ Simples de gerenciar, um único RBAC
- ❌ Isolamento zero, cotas compartilhadas
- **Uso:** lab, PoC, empresa muito pequena

### Padrão B — Pipeline em `ci`, PipelineRuns no namespace do projeto ⭐

- ✅ Isolamento por projeto (RBAC, cotas, secrets)
- ✅ Reuso do Pipeline como fonte única de verdade
- ✅ Modelo "plataforma como produto"
- ❌ Mais complexo — precisa cluster resolver + roteamento CEL
- **Uso:** múltiplas equipes, ambiente semi-produtivo

### Padrão C — Tudo via Bundles (OCI-only)

- ✅ Máxima portabilidade e versionamento
- ✅ GitOps-friendly
- ❌ Toda alteração de Pipeline vira push de bundle
- **Uso:** produção real, multi-cluster

---

## 3. Arquitetura final escolhida

Padrão B com aproveitamento dos Task Bundles já existentes.

```
┌─────────────────────────────────────────────────────────────┐
│  ns: ci                    ← concentrador (plataforma)      │
│                                                             │
│  ├─ Pipeline: java-app-pipeline                             │
│  │     (referencia Task Bundles via resolver: bundles)      │
│  ├─ EventListener: gitlab-listener                          │
│  ├─ Trigger com CEL interceptor (roteia por nome do repo)   │
│  ├─ TriggerBinding + TriggerTemplate                        │
│  ├─ ServiceAccount: tekton-triggers-sa                      │
│  ├─ Secret: gitlab-webhook-secret                           │
│  └─ RBAC: pode criar PipelineRuns em qualquer namespace     │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ CEL: 'proj-' + body.project.name
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  ns: proj-java-app         ← namespace do time              │
│                                                             │
│  ├─ ServiceAccount: pipeline-runner                         │
│  ├─ Secret: gitlab-basic-auth (anotado com URL do GitLab)   │
│  └─ PipelineRuns: java-app-run-xxx                          │
│      (criados pelo EL, com pipelineRef via cluster resolver)│
└─────────────────────────────────────────────────────────────┘
                            │
                            │ resolver: cluster
                            ▼
              Pipeline java-app-pipeline (no ci)
                            │
                            │ resolver: bundles
                            ▼
       Task Bundles no registry (git-clone, maven, kaniko)
```

### Padrão de nomes adotado

- **Namespace concentrador:** `ci`
- **Namespace de projeto:** `proj-<nome-do-repo>` (ex: `proj-java-app`)
- **ServiceAccount de execução:** `pipeline-runner` (por projeto)
- **Secret de auth Git:** `gitlab-basic-auth` (por projeto)

**Por que o prefixo `proj-`:**
- Separa visualmente de namespaces do sistema (`kube-system`, `tekton-pipelines`) e de infra (`ci`, `argocd`, `registry`)
- Facilita filtros: `kubectl get ns | grep proj-`
- Consistente com futura evolução (`app-<nome>-dev`/`-staging`/`-prod` para runtime)

---

## 4. Etapa 1.1 — Habilitar o cluster resolver

O **cluster resolver** permite que um `PipelineRun` num namespace referencie um `Pipeline` em outro. É o que torna o padrão B possível.

### 4.1. Habilitar a feature flag

```bash
kubectl -n tekton-pipelines patch cm feature-flags \
  --type merge -p '{"data":{"enable-cluster-resolver":"true"}}'
```

Validar:

```bash
kubectl -n tekton-pipelines get cm feature-flags \
  -o jsonpath='{.data.enable-cluster-resolver}'
echo
# esperado: true
```

### 4.2. Configurar quais namespaces o resolver pode alcançar

Por segurança, o cluster resolver é opt-in por namespace de origem:

```bash
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

Isso diz: "Qualquer namespace pode buscar Pipelines/Tasks no `ci`, mas só no `ci`."

### 4.3. Confirmar que o pod do resolver está de pé

```bash
kubectl get pods -n tekton-pipelines-resolvers
# esperado: tekton-pipelines-remote-resolvers-xxx  1/1  Running
```

---

## 5. Etapa 1.2 — Criar namespace do projeto

```bash
kubectl create ns proj-java-app

kubectl label ns proj-java-app tekton.dev/project=true
kubectl label ns proj-java-app app=java-app
```

O label `tekton.dev/project=true` é útil pra selecionar namespaces de projeto em queries futuras.

Confirmar:

```bash
kubectl get ns proj-java-app --show-labels
```

---

## 6. Etapa 1.3 — RBAC e secrets no namespace do projeto

Cada namespace de projeto tem suas próprias credenciais e SA. Isso é o que dá isolamento real.

### 6.1. Gerar o PAT no GitLab

Na UI do GitLab:
1. Clicar no avatar → **Preferences → Access tokens**
2. **Add new token**
3. Name: `tekton-proj-java-app`
4. Expiration: pode deixar em branco pra lab
5. Scopes: marcar `read_repository`
6. **Create personal access token**
7. **Copiar o valor imediatamente** (só aparece uma vez)

### 6.2. Criar o secret basic-auth

```bash
kubectl -n proj-java-app create secret generic gitlab-basic-auth \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=root \
  --from-literal=password='<PAT>'
```

### 6.3. Anotar com a URL do GitLab

A anotação `tekton.dev/git-0` diz ao Tekton "use esse secret quando clonar dessa URL":

```bash
kubectl -n proj-java-app annotate secret gitlab-basic-auth \
  tekton.dev/git-0=http://192.168.0.13:8929
```

### 6.4. Criar ServiceAccount dedicada com o secret anexado

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pipeline-runner
  namespace: proj-java-app
secrets:
- name: gitlab-basic-auth
EOF
```

O bloco `secrets` anexa automaticamente o secret aos pods de todas as Tasks executadas com essa SA.

### 6.5. Teste manual do cross-namespace

Antes de mexer no EL, valide que o cross-namespace funciona rodando um PipelineRun manual:

```bash
cat <<'EOF' | kubectl create -f -
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: cross-ns-test-
  namespace: proj-java-app
spec:
  taskRunTemplate:
    serviceAccountName: pipeline-runner
  pipelineRef:
    resolver: cluster
    params:
    - name: kind
      value: pipeline
    - name: name
      value: java-app-pipeline
    - name: namespace
      value: ci
  params:
  - name: repo-url
    value: http://192.168.0.13:8929/root/java-app.git
  - name: revision
    value: main
  - name: image
    value: registry.registry.svc.cluster.local:5000/apps/java-app:cross-ns-test
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

Detalhes críticos:
- `kubectl create` (não `apply`) — porque tem `generateName`
- `spec.taskRunTemplate.serviceAccountName: pipeline-runner` — na API `v1`, é aqui que a SA vai (não em `spec.serviceAccountName` como era na `v1beta1`)
- `pipelineRef.resolver: cluster` — cross-namespace lookup

Acompanhar:

```bash
kubectl -n proj-java-app get pipelinerun -w
```

Deve terminar com `SUCCEEDED=True`. Se falhar no clone com "could not read Username", o secret não foi anexado corretamente à SA. Reverifique 6.3 e 6.4.

---

## 7. Etapa 1.4 — EventListener multi-namespace com CEL

Aqui reconfiguramos o EL centralizado pra:
- Extrair o nome do repo do payload
- Calcular o namespace de destino (`proj-<repo>`)
- Criar o `PipelineRun` no namespace correto

### 7.1. RBAC — permitir que o EL crie PipelineRuns em qualquer namespace

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

### 7.2. Trigger com dois interceptors: `gitlab` + `cel`

O interceptor `cel` calcula o namespace destino dinamicamente:

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
    - name: overlays
      value:
      - key: target-namespace
        expression: "'proj-' + body.project.name"
      - key: repo-name
        expression: "body.project.name"
  bindings:
  - ref: gitlab-push-binding
  template:
    ref: java-app-template
EOF
```

**Como o CEL funciona aqui:**
- `body.project.name` vem do payload do GitLab — pro repo `java-app`, vale `"java-app"`
- Concatenação `'proj-' + body.project.name` → `"proj-java-app"`
- Isso vira `extensions.target-namespace` e fica disponível pro `TriggerBinding`

### 7.3. TriggerBinding — passar as extensões CEL adiante

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
EOF
```

### 7.4. TriggerTemplate — criar PipelineRun no namespace calculado

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: java-app-template
  namespace: ci
spec:
  params:
  - name: repo-url
  - name: revision
  - name: short-sha
  - name: target-namespace
  - name: repo-name
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
          value: java-app-pipeline
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

Mudanças chave em relação à versão anterior:
- `generateName` usa o nome do repo (`java-app-run-`)
- `namespace` é dinâmico via `$(tt.params.target-namespace)`
- `taskRunTemplate.serviceAccountName: pipeline-runner` (a SA no namespace do projeto)
- `pipelineRef` via `cluster` resolver
- Imagem final usa o nome do repo automaticamente (`apps/java-app:<sha>`)

### 7.5. Reiniciar o pod do EL

O EL precisa recarregar as configurações:

```bash
kubectl -n ci delete pod -l eventlistener=gitlab-listener
kubectl -n ci get pods -l eventlistener=gitlab-listener -w
```

Espere `1/1 Running` antes de testar.

---

## 8. Etapa 1.5 — Validação end-to-end

### 8.1. Push real no repo Java

```bash
cd ~/java-app-demo
echo "// $(date)" >> src/main/java/com/example/App.java
git add .
git commit -m "Testando padrão B"
git push
```

### 8.2. Monitorar

Terminal 1 — log do EL:
```bash
kubectl -n ci logs -l eventlistener=gitlab-listener -f --timestamps
```

Terminal 2 — PipelineRun no novo namespace:
```bash
kubectl -n proj-java-app get pipelinerun -w
```

### 8.3. Confirmar sucesso

```bash
kubectl get pipelinerun -A | grep java-app-run
```

Saída esperada — repare que o novo run está em `proj-java-app`:

```
proj-java-app   java-app-run-b5g4l   True   Succeeded   4m   3m
```

### 8.4. Confirmar a imagem no registry

```bash
curl -s http://192.168.56.110:32000/v2/apps/java-app/tags/list
```

Deve mostrar a tag com o SHA do commit.

---

## 9. Como adicionar um novo projeto

Adicionar um segundo projeto (ex: `node-app`) agora é um procedimento repetível de 3 comandos:

```bash
# 1. Criar namespace
kubectl create ns proj-node-app
kubectl label ns proj-node-app tekton.dev/project=true app=node-app

# 2. Criar secret com PAT do GitLab (gerar PAT específico do projeto antes)
kubectl -n proj-node-app create secret generic gitlab-basic-auth \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=root \
  --from-literal=password='<PAT_NODE_APP>'

kubectl -n proj-node-app annotate secret gitlab-basic-auth \
  tekton.dev/git-0=http://192.168.0.13:8929

# 3. Criar ServiceAccount
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pipeline-runner
  namespace: proj-node-app
secrets:
- name: gitlab-basic-auth
EOF
```

Cadastrar o webhook do novo repo no GitLab apontando pro mesmo `http://192.168.56.110:32080`. O CEL cuida do roteamento automaticamente.

**Observação:** se o `node-app` usar um Pipeline diferente (por exemplo `node-app-pipeline` em vez de `java-app-pipeline`), o `TriggerTemplate` precisa ser ajustado ou você cria um `Trigger` por tipo de app. Um jeito comum é usar mais CEL pra escolher qual Pipeline aplicar:

```yaml
- key: pipeline-name
  expression: |
    body.project.name.endsWith('-java') ? 'java-app-pipeline' :
    body.project.name.endsWith('-node') ? 'node-app-pipeline' :
    'default-pipeline'
```

---

## 10. Prompts para diagramas com Gemini

### Prompt 1 — Arquitetura multi-tenant (padrão B)

```
Create a professional Kubernetes multi-tenant CI/CD architecture diagram:

Center-top: a large rectangle labeled "namespace: ci (Platform)" containing:
- "Pipeline: java-app-pipeline"
- "EventListener: gitlab-listener"
- "Trigger with CEL interceptor"
- "TriggerBinding + TriggerTemplate"
- "ServiceAccount: tekton-triggers-sa"
- "ClusterRoleBinding: create PipelineRuns cross-namespace"

Below, three separate rectangles for tenant namespaces:
- "namespace: proj-java-app"
- "namespace: proj-node-app (future)"
- "namespace: proj-python-app (future)"

Each tenant namespace contains:
- "ServiceAccount: pipeline-runner"
- "Secret: gitlab-basic-auth"
- "PipelineRuns"

Arrows:
- Downward arrow from ci to proj-java-app labeled 
  "CEL routes based on repo name → 'proj-' + body.project.name"
- Arrow from PipelineRun back up to ci labeled 
  "resolver: cluster (fetches Pipeline)"
- Arrow from Pipeline to a small box on the right labeled "Registry (Task Bundles)"
  with label "resolver: bundles"

Style: clean cloud-native architecture diagram, blue and green palette, 
Kubernetes-themed, English labels, white background, professional.
```

### Prompt 2 — Fluxo do webhook até o namespace do projeto

```
Create a horizontal end-to-end sequence diagram showing multi-tenant 
CI routing:

Step 1: Developer git push to "java-app" repo in GitLab
Step 2: GitLab sends webhook POST to EventListener in namespace "ci"
Step 3: gitlab interceptor validates X-Gitlab-Token
Step 4: cel interceptor computes target namespace: 
        "'proj-' + body.project.name" = "proj-java-app"
Step 5: TriggerTemplate creates PipelineRun in namespace "proj-java-app" 
        with SA "pipeline-runner"
Step 6: PipelineRun references Pipeline "java-app-pipeline" from namespace 
        "ci" via cluster resolver
Step 7: Tasks (git-clone, maven-build, kaniko) execute, using 
        "gitlab-basic-auth" secret local to proj-java-app
Step 8: Final image pushed to internal Registry as "apps/java-app:<sha>"

Highlight namespace boundaries visually. Use different colors for "ci" 
(platform) vs "proj-java-app" (tenant).

Style: modern horizontal flow diagram, isometric or 2D flat, professional 
DevOps documentation, English labels, white background.
```

### Prompt 3 — Padrão de crescimento multi-projeto

```
Create a scalability diagram showing how the multi-tenant Tekton platform 
grows with new projects:

Left: single "Platform namespace (ci)" with icons for EventListener, 
Pipeline definitions, RBAC

Right side: 5 tenant namespaces stacked vertically, each with same 
internal structure (SA, Secret, PipelineRuns):
- proj-java-app
- proj-node-app
- proj-python-app
- proj-frontend
- proj-mobile-api

Between the platform and tenants, a single CEL routing arrow labeled 
"CEL: 'proj-' + body.project.name"

Emphasize that adding a new project only requires: 
1. Create namespace 
2. Create SA + Secret 
3. Register webhook

No changes needed to the platform namespace.

Style: cloud-native scalability diagram, blue/purple gradient, 
minimal and professional, English labels, white background, 
suitable for architecture presentations.
```

---

## 11. Troubleshooting

### 11.1. `cannot use generate name with apply`

**Sintoma:**
```
error: from cross-ns-test-: cannot use generate name with apply
```

**Causa:** `kubectl apply` precisa saber o nome exato do recurso pra reconciliar. Recursos com `generateName` (nome gerado dinamicamente) só funcionam com `kubectl create`.

**Solução:** trocar `apply` por `create`. Para YAMLs sem `generateName` (Trigger, TriggerBinding, TriggerTemplate, EventListener, RBAC), `apply` funciona normalmente.

### 11.2. PipelineRun falha no clone com "could not read Username"

**Sintoma:** log da task clone:
```
fatal: could not read Username for 'http://192.168.0.13:8929': 
No such device or address
```

Mesmo com o secret criado no `proj-java-app`.

**Causas possíveis:**

1. **PipelineRun está usando SA `default`** (que não tem o secret). No `describe` aparece `Service Account: default`.
   - **Solução:** verificar que o PipelineRun usa `spec.taskRunTemplate.serviceAccountName: pipeline-runner`.

2. **API `v1` vs `v1beta1`:** na API `v1`, a SA vai em `spec.taskRunTemplate.serviceAccountName`, não em `spec.serviceAccountName`.
   - **Solução:** ajustar o `TriggerTemplate` conforme:
     ```yaml
     spec:
       taskRunTemplate:
         serviceAccountName: pipeline-runner
     ```

3. **Anotação errada no secret.**
   - **Solução:**
     ```bash
     kubectl -n proj-java-app get secret gitlab-basic-auth -o yaml | grep -A2 annotations
     # deve mostrar: tekton.dev/git-0: http://192.168.0.13:8929
     ```

### 11.3. EL retorna 202 mas PipelineRun não é criado no namespace do projeto

**Diagnóstico:**

1. Log do EL:
```bash
kubectl -n ci logs -l eventlistener=gitlab-listener --tail=50
```

2. Se aparecer `forbidden` mencionando `pipelineruns` — falta o `ClusterRoleBinding` da etapa 7.1.
3. Se aparecer o log de criação mas o run não aparecer — provavelmente o `target-namespace` foi calculado errado (namespace inexistente ou nome inválido). Confira o valor:
```bash
kubectl -n ci logs -l eventlistener=gitlab-listener --tail=50 | grep target-namespace
```

### 11.4. Cluster resolver retorna `ResolutionFailed`

**Sintoma:** PipelineRun fica com status `Failed` imediatamente, `describe` mostra:
```
Reason: ResolutionFailed
Message: unable to resolve resource ...
```

**Causas:**

1. **Feature flag desligada** — reverifique:
```bash
kubectl -n tekton-pipelines get cm feature-flags \
  -o jsonpath='{.data.enable-cluster-resolver}'
```

2. **`cluster-resolver-config` não permitindo o namespace de origem** — verifique:
```bash
kubectl -n tekton-pipelines-resolvers get cm cluster-resolver-config -o yaml
```

3. **Pipeline não existe em `ci`**:
```bash
kubectl -n ci get pipeline java-app-pipeline
```

### 11.5. CEL interceptor não gera `extensions`

**Sintoma:** `TriggerBinding` recebe `target-namespace` vazio, PipelineRun tenta ser criado no namespace `""`.

**Causa comum:** interceptor `cel` não está registrado como `ClusterInterceptor`.

**Diagnóstico:**
```bash
kubectl get clusterinterceptors | grep cel
```

Se não aparecer, o `interceptors.yaml` do Triggers não foi aplicado. Reaplique:
```bash
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
```

### 11.6. Kaniko não empurra a imagem — falta pull do registry no novo namespace

**Sintoma:** kaniko falha com erro genérico de rede/registry.

**Causa:** o `registries.yaml` do k3s já cobre o registry inseguro em todos os nós. Se falhar mesmo assim, verificar que o container `kaniko` está saindo pelo IP interno e não por proxy.

---

## 12. Próximos passos do roadmap

Com o padrão B validado, o roadmap sugerido é:

1. **Passo 2 — Testes no pipeline** — adicionar Task `maven-test` antes do build, com JaCoCo pra coverage
2. **Passo 3 — ArgoCD para o CD** — repo GitOps + Applications sincronizando manifests
3. **Passo 4 — Segurança** — Trivy scan na imagem, Cosign para assinatura
4. **Passo 5 — Observabilidade** — Prometheus + Grafana + Loki
5. **Passo 6 — Promoção entre ambientes** — dev → staging → prod via MR

Cada um se encaixa sem quebrar o que temos: os namespaces `proj-<app>` continuam sendo os pontos de isolamento por projeto, e o padrão B fica sendo o alicerce do resto.

---

## Referências

- [Tekton Cluster Resolver](https://tekton.dev/docs/pipelines/cluster-resolver/)
- [Tekton CEL Interceptor](https://tekton.dev/docs/triggers/cel_expressions/)
- [Tekton Auth for Git](https://tekton.dev/docs/pipelines/auth/#configuring-basic-auth-authentication-for-git)
- [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
