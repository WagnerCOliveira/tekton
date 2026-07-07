# Troubleshooting — Tekton no k3s

Problemas encontrados durante a montagem e operação da plataforma, organizados por categoria. Para contexto de cada componente, consulte os documentos principais.

---

## Sumário

1. [Instalação do Tekton](#1-instalação-do-tekton)
2. [Registry Docker interno](#2-registry-docker-interno)
3. [Task Bundles](#3-task-bundles)
4. [RBAC e EventListener](#4-rbac-e-eventlistener)
5. [GitLab e Webhooks](#5-gitlab-e-webhooks)
6. [Autenticação Git e Clone](#6-autenticação-git-e-clone)
7. [Multi-tenant e CEL](#7-multi-tenant-e-cel)
8. [Kubernetes geral](#8-kubernetes-geral)

---

## 1. Instalação do Tekton

### 1.1. Race condition entre Pipelines e Triggers

**Sintoma:**
```
Error from server (InternalError): failed calling webhook
"config.webhook.pipeline.tekton.dev": ... no endpoints available
for service "tekton-pipelines-webhook"
```

**Causa:** o `apply` dos Triggers começou antes do webhook do Pipelines terminar de subir.

**Solução:** aguardar o webhook antes de instalar Triggers:
```bash
kubectl -n tekton-pipelines wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=webhook --timeout=180s

# Reaplicar Triggers (idempotente)
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
```

---

### 1.2. Download do `tkn` CLI quebrado

**Sintoma:**
```
gzip: stdin: not in gzip format
tar: Error is not recoverable: exiting now
```

**Causa:** a URL `latest/download/` retornou um HTML de redirect em vez do binário.

**Solução:** usar URL versionada explícita via API do GitHub:
```bash
LATEST=$(curl -s https://api.github.com/repos/tektoncd/cli/releases/latest \
  | grep tag_name | cut -d'"' -f4)
VERSION=${LATEST#v}
curl -LO "https://github.com/tektoncd/cli/releases/download/${LATEST}/tkn_${VERSION}_Linux_x86_64.tar.gz"
file tkn_${VERSION}_Linux_x86_64.tar.gz   # verificar que é gzip antes de descompactar
sudo tar xvzf tkn_${VERSION}_Linux_x86_64.tar.gz -C /usr/local/bin/ tkn
```

---

## 2. Registry Docker interno

### 2.1. Imagem rejeitada — "HTTP response to HTTPS client"

**Sintoma:** pod não puxa imagem do registry interno. Log do containerd:
```
http: server gave HTTP response to HTTPS client
```

**Causa:** `/etc/rancher/k3s/registries.yaml` não foi criado no nó, ou o k3s não foi reiniciado após a criação.

**Solução:** verificar o arquivo em cada nó e reiniciar:
```bash
ls -la /etc/rancher/k3s/registries.yaml
sudo systemctl restart k3s         # no k3s-server
sudo systemctl restart k3s-agent   # nos agents
```

O arquivo `registries.yaml` deve conter **as duas** entradas — DNS interno e IP:NodePort:
```yaml
mirrors:
  "registry.registry.svc.cluster.local:5000":
    endpoint:
      - "http://registry.registry.svc.cluster.local:5000"
  "192.168.56.110:32000":
    endpoint:
      - "http://192.168.56.110:32000"
configs:
  "registry.registry.svc.cluster.local:5000":
    tls:
      insecure_skip_verify: true
  "192.168.56.110:32000":
    tls:
      insecure_skip_verify: true
```

---

### 2.2. Pods não resolvem o DNS interno do registry

**Sintoma:** pull via `IP:NodePort` funciona, mas via DNS `registry.registry.svc.cluster.local` falha.

**Diagnóstico:**
```bash
kubectl run test --rm -it --restart=Never --image=curlimages/curl -- \
  curl http://registry.registry.svc.cluster.local:5000/v2/_catalog
```

**Causa:** a entrada DNS interna não está no `registries.yaml`. Ele precisa ter as **duas** entradas (DNS interno + IP:NodePort).

---

## 3. Task Bundles

### 3.1. `tkn bundle push` — arquivo não encontrado

**Sintoma:**
```
Error: failed to find and read file tasks/git-clone.yaml:
open tasks/git-clone.yaml: no such file or directory
```

**Causa:** os arquivos YAML das Tasks não foram criados antes do push.

**Solução:** criar os arquivos primeiro (`cat > tasks/xxx.yaml <<'EOF' ... EOF`), depois publicar.

---

### 3.2. `tkn bundle push` — "not YAML or JSON parseable"

**Sintoma:**
```
Error: found a spec that isn't YAML or JSON parseable
```

**Causa:** a Task tem `$(comando)` no script shell (ex: `$(node --version)`). O Tekton usa `$(...)` como sintaxe própria de expressão e conflita com o parser YAML.

**Solução:** remover ou reescrever as linhas que usam substituição de comando:

```yaml
# ❌ Ruim — $(node --version) é interpretado pelo Tekton
script: |
  echo "Version: $(node --version)"

# ✅ Bom — usar arquivo temporário
script: |
  node --version > /tmp/nv
  echo "Version: $(cat /tmp/nv)"
```

---

### 3.3. Kaniko falha ao empurrar para o registry

**Sintoma:** erro tipo `x509: certificate signed by unknown authority` ou `http response to HTTPS client` no log do kaniko.

**Causa:** flags de registry inseguro faltando na Task.

**Solução:** confirmar que a Task `kaniko-build-push` tem **todos** estes args:
```yaml
args:
  - --insecure
  - --skip-tls-verify
  - --insecure-pull
  - --skip-tls-verify-pull
```

---

### 3.4. Task Bundle sobrescrito quebra runs em andamento

**Comportamento:** se você sobrescrever uma tag existente (ex: `:v1`), PipelineRuns em execução podem usar a versão antiga em cache enquanto novos runs baixam a nova versão sem aviso. Não há rollback rápido.

**Regra:** nunca sobrescrever um Task Bundle em uso. Sempre publicar com tag nova (`:v2`, `:v3`) e migrar os Pipelines conscientemente.

---

## 4. RBAC e EventListener

### 4.1. EventListener em CrashLoopBackOff — ClusterRoleBinding faltando

**Sintoma:** pod `el-<listener>-xxx` fica reiniciando. Log:
```
clusterinterceptors.triggers.tekton.dev is forbidden:
User "system:serviceaccount:...:tekton-triggers-sa" cannot list resource
"clusterinterceptors" in API group "triggers.tekton.dev" at the cluster scope
```

**Causa:** o EventListener precisa de **duas** bindings — a namespaced e a cluster-scoped. A segunda está faltando.

**Solução:** aplicar o ClusterRoleBinding:
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: <sa-name>-cluster
subjects:
- kind: ServiceAccount
  name: <sa-name>
  namespace: <namespace>
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tekton-triggers-eventlistener-clusterroles
EOF

# Forçar reinício do pod
kubectl -n <namespace> delete pod -l eventlistener=<listener>
```

---

### 4.2. EL retorna 202 mas nenhum PipelineRun é criado (cross-namespace)

**Sintoma:** GitLab mostra "HTTP 202 success", mas `kubectl get pipelinerun -A` continua vazio.

**Diagnóstico:**
```bash
kubectl -n ci logs -l eventlistener=gitlab-listener --tail=50
```

**Causa A — `forbidden` no log:** falta o `ClusterRoleBinding` que dá permissão para criar PipelineRuns em outros namespaces:
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

**Causa B — token errado:** o interceptor `gitlab` rejeita silenciosamente quando o `X-Gitlab-Token` não bate com o secret.

Simular um POST com o token real para isolar:
```bash
TOKEN=$(kubectl -n ci get secret gitlab-webhook-secret \
  -o jsonpath='{.data.secretToken}' | base64 -d)

kubectl -n ci run curl-sim --rm -i --restart=Never --image=curlimages/curl:latest -- \
  curl -v -X POST \
  -H "Content-Type: application/json" \
  -H "X-Gitlab-Event: Push Hook" \
  -H "X-Gitlab-Token: $TOKEN" \
  -d '{"object_kind":"push","checkout_sha":"test1234","project":{"name":"backend-example"},"repository":{"git_http_url":"http://example/repo.git"}}' \
  http://el-gitlab-listener.ci.svc.cluster.local:8080
```

Se funcionar com esse curl mas não com o do GitLab → o token no webhook do GitLab divergiu. Recopie o valor e salve novamente no GitLab.

---

## 5. GitLab e Webhooks

### 5.1. "Invalid url given" ao salvar o webhook

**Sintoma:** ao tentar salvar webhook com URL `http://192.168.56.110:32080`, o GitLab recusa com "Invalid url given".

**Causa:** proteção SSRF do GitLab bloqueia webhooks para redes privadas/locais por padrão.

**Solução:** liberar na Admin Area:
1. **Admin Area → Settings → Network → Outbound requests**
2. Marcar:
   - ☑ Allow requests to the local network from webhooks and integrations
   - ☑ Allow requests to the local network from system hooks
3. **Save changes**

---

### 5.2. Webhook: "Connection refused"

**Sintoma:**
```
Hook execution failed: Failed to open TCP connection to 192.168.56.110:32080
(Connection refused - connect(2))
```

**Diagnóstico:** testar de dentro do container GitLab:
```bash
docker exec gitlab curl -v http://192.168.56.110:32080
```

**Causa:** o container do GitLab está na rede Docker (`172.18.0.0/16`) e não consegue rotear para `192.168.56.0/24`.

**Solução:** usar `network_mode: host` no `docker-compose.yml`:
```yaml
services:
  gitlab:
    network_mode: host        # ADICIONAR
    # ports:                  # REMOVER (incompatível com host mode)
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://192.168.56.1:8929'
        nginx['listen_port'] = 8929   # obrigatório sem ports:
```

```bash
docker compose down
docker compose up -d
```

---

## 6. Autenticação Git e Clone

### 6.1. "could not read Username for..."

**Sintoma no log da task `git-clone`:**
```
fatal: could not read Username for 'http://192.168.56.1:8929':
No such device or address
```

**Causas possíveis, em ordem de probabilidade:**

**A) PipelineRun usando SA `default`** — verificar:
```bash
tkn pipelinerun describe <name> -n <ns> | grep "Service Account"
```
Se aparecer `default`, o `TriggerTemplate` não está passando `serviceAccountName: pipeline-runner`.

Na API `v1`, a SA vai em `spec.taskRunTemplate.serviceAccountName` (não em `spec.serviceAccountName` como era na `v1beta1`):
```yaml
spec:
  taskRunTemplate:
    serviceAccountName: pipeline-runner   # ← posição correta na v1
```

**B) Anotação do secret incorreta ou ausente:**
```bash
kubectl -n <ns> get secret gitlab-basic-auth -o yaml | grep -A2 annotations
# deve mostrar: tekton.dev/git-0: http://192.168.56.1:8929
```

**C) PAT expirado ou com scope errado** — precisa `read_repository`.

**Solução B (lab rápido):** mudar o projeto para **Public** em **Settings → General → Visibility → Public**.

**Solução C (produção):** criar PAT + secret com anotação + anexar à SA:
```bash
kubectl -n <ns> create secret generic gitlab-basic-auth \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=root \
  --from-literal=password='<PAT>'

kubectl -n <ns> annotate secret gitlab-basic-auth \
  tekton.dev/git-0=http://192.168.56.1:8929

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pipeline-runner
  namespace: <ns>
secrets:
- name: gitlab-basic-auth
EOF
```

---

### 6.2. PipelineRun falha com SHA inexistente

**Sintoma:**
```
fatal: pathspec 'abc1234' did not match any file(s) known to git
```

**Causa:** durante testes manuais foi passado um SHA fictício.

**Solução:** usar SHA real do repo. Em push events reais, `body.checkout_sha` sempre contém o SHA correto.

---

## 7. Multi-tenant e CEL

### 7.1. CEL não gera `extensions` — namespace calculado vira `""`

**Sintoma:** TriggerBinding recebe `target-namespace` vazio. PipelineRun é criado no namespace `""` (falha imediatamente).

**Causa:** interceptor `cel` não está registrado como `ClusterInterceptor` no cluster.

**Diagnóstico:**
```bash
kubectl get clusterinterceptors | grep cel
```

**Solução:** reaplicar os interceptors do Triggers:
```bash
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
```

---

### 7.2. Cluster resolver retorna `ResolutionFailed`

**Sintoma:** PipelineRun falha imediatamente com:
```
Reason: ResolutionFailed
Message: unable to resolve resource ...
```

**Causas e diagnósticos:**

```bash
# 1. Feature flag habilitada?
kubectl -n tekton-pipelines get cm feature-flags \
  -o jsonpath='{.data.enable-cluster-resolver}'
# esperado: true

# 2. ConfigMap com os namespaces permitidos?
kubectl -n tekton-pipelines-resolvers get cm cluster-resolver-config -o yaml

# 3. Pipeline existe no ci?
kubectl -n ci get pipeline java-app-pipeline
```

Causa comum: o CEL calculou `pipeline-name: UNKNOWN` (repo sem prefixo). O Pipeline com esse nome não existe.

---

### 7.3. `npm ci` falha com "requires package-lock.json"

**Sintoma:**
```
The `npm ci` command can only install with an existing package-lock.json
```

**Causa:** repo não tem `package-lock.json` (criado manualmente sem rodar `npm install` local antes).

**Soluções:**

Opção A — forçar `npm install` na Task:
```yaml
params:
- name: install-command
  value: "npm install"
```

Opção B — gerar o lock file e commitar:
```bash
npm install
git add package-lock.json
git commit -m "Add lock file"
git push
```

---

### 7.4. Task `node-build` — output estranho no log

**Sintoma:**
```
[install] Node: 12(node --version)
[install] npm:  12(npm --version)
```

**Causa:** `$(node --version)` dentro do script da Task é interpretado pela sintaxe de expressão do Tekton antes de chegar ao shell.

**Solução:** remover essas linhas de debug. Não há escapamento funcional para `$(comando)` dentro de `script` no Tekton.

---

## 8. Kubernetes geral

### 8.1. `cannot use generate name with apply`

**Sintoma:**
```
error: from cross-ns-test-: cannot use generate name with apply
```

**Causa:** `kubectl apply` precisa do nome exato do recurso para reconciliar. Recursos com `generateName` (nome gerado dinamicamente) exigem `kubectl create`.

**Solução:** usar `kubectl create` para PipelineRuns com `generateName`. Para recursos com `name` fixo (Trigger, TriggerBinding, TriggerTemplate, EventListener, RBAC), `apply` funciona normalmente.

---

### 8.2. Namespace preso em "Terminating"

**Sintoma:**
```
unable to create new content in namespace X because it is being terminated
```

**Causa:** algum recurso com finalizer travado (comum quando o EventListener é deletado antes do namespace).

**Solução:** listar recursos com finalizers e remover:
```bash
kubectl get all -n <ns>
kubectl -n <ns> patch <resource>/<name> \
  --type merge -p '{"metadata":{"finalizers":[]}}'
```

---

## Referências rápidas de diagnóstico

```bash
# Status geral da plataforma
kubectl -n ci get pipeline,trigger,triggerbinding,triggertemplate,eventlistener,sa,secret,pods

# Log do EventListener em tempo real
kubectl -n ci logs -l eventlistener=gitlab-listener -f --timestamps

# Últimos runs em todos os namespaces
kubectl get pipelinerun -A --sort-by=.metadata.creationTimestamp | tail -20

# Token atual do webhook
kubectl -n ci get secret gitlab-webhook-secret \
  -o jsonpath='{.data.secretToken}' | base64 -d && echo

# Interceptors registrados
kubectl get clusterinterceptors

# Feature flags do Tekton
kubectl -n tekton-pipelines get cm feature-flags -o yaml | grep -E "enable-"
```
