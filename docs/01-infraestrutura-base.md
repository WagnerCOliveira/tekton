# Infraestrutura de CI/CD com Tekton em Cluster k3s

Guia de instalação e configuração da infraestrutura base: Tekton em cluster **k3s** local (1 server + 2 agents), **Task Bundles** em registry interno e webhook do **GitLab Community**.

> Para evolução multi-tenant, consulte [docs/02-arquitetura-multitenant.md](02-arquitetura-multitenant.md).
> Para operação da plataforma, consulte [docs/04-ci-operacional.md](04-ci-operacional.md).
> Para problemas conhecidos, consulte [docs/05-troubleshooting.md](05-troubleshooting.md).

---

## Sumário

1. [Arquitetura e visão geral](#1-arquitetura-e-visão-geral)
2. [Fluxos e diagramas](#2-fluxos-e-diagramas)
3. [Pré-requisitos](#3-pré-requisitos)
4. [Fase 1 — Instalação do Tekton](#4-fase-1--instalação-do-tekton)
5. [Fase 2 — Registry interno no cluster](#5-fase-2--registry-interno-no-cluster)
6. [Fase 3 — Tasks e publicação como Task Bundles](#6-fase-3--tasks-e-publicação-como-task-bundles)
7. [Fase 4 — Pipeline consumindo os Bundles](#7-fase-4--pipeline-consumindo-os-bundles)
8. [Fase 5 — GitLab Community via Docker Compose](#8-fase-5--gitlab-community-via-docker-compose)
9. [Fase 6 — App Java de exemplo](#9-fase-6--app-java-de-exemplo)
10. [Fase 7 — Triggers e webhook do GitLab](#10-fase-7--triggers-e-webhook-do-gitlab)
11. [Fase 8 — Autenticação Git no clone](#11-fase-8--autenticação-git-no-clone)
12. [Fase 9 — Tekton Dashboard](#12-fase-9--tekton-dashboard)

---

## 1. Arquitetura e visão geral

O objetivo é montar uma pipeline de CI que:

1. Recebe um `Push Hook` do GitLab
2. É autenticada por um secret compartilhado (interceptor `gitlab` do Tekton Triggers)
3. Executa um Pipeline que faz **clone → build (Maven) → build+push da imagem (Kaniko)**
4. Publica a imagem final em um **registry Docker interno** do cluster
5. Todas as Tasks são referenciadas como **Task Bundles** (artefatos OCI armazenados no mesmo registry)

### Componentes

| Componente | Onde roda | Função |
|---|---|---|
| **Tekton Pipelines** | ns `tekton-pipelines` | Executa Tasks e Pipelines |
| **Tekton Triggers** | ns `tekton-pipelines` | Recebe eventos HTTP e cria PipelineRuns |
| **Interceptors** | ns `tekton-pipelines` | Valida assinatura do GitLab |
| **Tekton Dashboard** | ns `tekton-pipelines` | UI web para observabilidade |
| **Bundles Resolver** | ns `tekton-pipelines-resolvers` | Puxa Task Bundles do registry OCI |
| **Docker Registry v2** | ns `registry` | Guarda bundles + imagens finais |
| **GitLab CE** | Host (Docker Compose, `network_mode: host`) | SCM + emissor de webhooks |

---

## 2. Fluxos e diagramas

### Fluxo 1 — Topologia de rede

![Topologia de rede](../imagens/diagrama-de-topologia-de-rede.png)


### Fluxo 2 — Sequência de instalação

![Sequência de instalação](../imagens/fluxograma-de-instalacao-fases-1-a-9.png)

### Fluxo 3 — Ciclo de vida do webhook até imagem no registry

![Ciclo de vida do webhook até imagem no registry](../imagens/fluxo-do-webhook-ate-a-imagem-publicada.png)


### Fluxo 4 — RBAC do EventListener (armadilha do Triggers)

![RBAC do EventListener (armadilha do Triggers)](../imagens/RBAC-do-eventListener.png)


---

## 3. Pré-requisitos

- Cluster k3s (1 server + 2 agents) funcional
- `kubectl` configurado no server
- Acesso root/sudo nos 3 nós
- Docker + Docker Compose no host
- Rede entre host e VMs funcionando (rede libvirt)

Confirmar:

```bash
kubectl version
kubectl get nodes -o wide
```

Deve mostrar `Server Version: vX.Y.Z+k3s1` e três nós `Ready`.

---

## 4. Fase 1 — Instalação do Tekton

### 4.1. Instalar Pipelines

```bash
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
```

**Importante:** aguarde o webhook antes de instalar Triggers.

```bash
kubectl -n tekton-pipelines wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=webhook --timeout=180s
```

### 4.2. Instalar Triggers e Interceptors

```bash
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
```

Se o primeiro apply falhar com `no endpoints available for service "tekton-pipelines-webhook"`, aguarde 30s e reaplique (é idempotente).

### 4.3. Instalar o Dashboard

```bash
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
```

### 4.4. Habilitar o bundles resolver

```bash
kubectl -n tekton-pipelines patch cm feature-flags \
  --type merge -p '{"data":{"enable-bundles-resolver":"true"}}'

kubectl -n tekton-pipelines get cm feature-flags \
  -o jsonpath='{.data.enable-bundles-resolver}'
```

### 4.5. Validação

```bash
kubectl get pods -n tekton-pipelines
kubectl get pods -n tekton-pipelines-resolvers
kubectl get crds | grep tekton
kubectl get clusterinterceptors
```

Interceptors esperados: `gitlab`, `github`, `bitbucket`, `cel`, `slack`.

### 4.6. Smoke test do Pipelines

```bash
kubectl create ns tekton-test

cat <<'EOF' | kubectl apply -f -
apiVersion: tekton.dev/v1
kind: TaskRun
metadata:
  name: hello-world
  namespace: tekton-test
spec:
  taskSpec:
    steps:
    - name: say-hi
      image: alpine:3.19
      script: |
        #!/bin/sh
        echo "Tekton está funcionando!"
EOF

kubectl -n tekton-test get taskrun hello-world -w
```

### 4.7. Smoke test do Triggers (revela armadilha do RBAC)

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: test-sa
  namespace: tekton-test
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: test-sa-eventlistener
  namespace: tekton-test
subjects:
- kind: ServiceAccount
  name: test-sa
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tekton-triggers-eventlistener-roles
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: test-sa-eventlistener-cluster
subjects:
- kind: ServiceAccount
  name: test-sa
  namespace: tekton-test
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tekton-triggers-eventlistener-clusterroles
---
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: test-tt
  namespace: tekton-test
spec:
  resourcetemplates:
  - apiVersion: tekton.dev/v1
    kind: TaskRun
    metadata:
      generateName: triggered-hello-
    spec:
      taskSpec:
        steps:
        - name: echo
          image: alpine:3.19
          script: echo "Disparado via webhook!"
---
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: test-el
  namespace: tekton-test
spec:
  serviceAccountName: test-sa
  triggers:
  - template:
      ref: test-tt
EOF
```

Testar POST:

```bash
kubectl -n tekton-test run curl-test --rm -it --restart=Never \
  --image=curlimages/curl:latest -- \
  curl -X POST -H "Content-Type: application/json" -d '{}' \
  http://el-test-el.tekton-test.svc.cluster.local:8080
```

Resposta esperada: `{"eventListener":"test-el",...,"eventID":"..."}`.

### 4.8. Limpeza

```bash
kubectl delete ns tekton-test
kubectl delete clusterrolebinding test-sa-eventlistener-cluster
```

---

## 5. Fase 2 — Registry interno no cluster

### 5.1. Deploy do Docker Registry v2

`registry.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: registry
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-data
  namespace: registry
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 20Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: registry
spec:
  replicas: 1
  selector:
    matchLabels: { app: registry }
  template:
    metadata:
      labels: { app: registry }
    spec:
      containers:
      - name: registry
        image: registry:2
        ports:
        - containerPort: 5000
        env:
        - name: REGISTRY_STORAGE_DELETE_ENABLED
          value: "true"
        - name: REGISTRY_HTTP_ADDR
          value: ":5000"
        volumeMounts:
        - name: data
          mountPath: /var/lib/registry
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: registry-data
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: registry
spec:
  type: NodePort
  selector: { app: registry }
  ports:
  - port: 5000
    targetPort: 5000
    nodePort: 32000
```

```bash
kubectl apply -f registry.yaml
kubectl -n registry get pods -w
```

### 5.2. Validar

```bash
IP_SERVER=$(kubectl get node k3s-server -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
curl http://$IP_SERVER:32000/v2/
```

Retorno esperado: `{}`.

### 5.3. Configurar k3s pra aceitar o registry inseguro

Em **cada um dos 3 nós**, criar `/etc/rancher/k3s/registries.yaml`:

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

Reiniciar o serviço em cada nó:

```bash
# No k3s-server
sudo systemctl restart k3s

# Nos agents
sudo systemctl restart k3s-agent
```

### 5.4. Instalar o `tkn` CLI no server

```bash
LATEST=$(curl -s https://api.github.com/repos/tektoncd/cli/releases/latest | grep tag_name | cut -d'"' -f4)
VERSION=${LATEST#v}
curl -LO "https://github.com/tektoncd/cli/releases/download/${LATEST}/tkn_${VERSION}_Linux_x86_64.tar.gz"
file tkn_${VERSION}_Linux_x86_64.tar.gz
sudo tar xvzf tkn_${VERSION}_Linux_x86_64.tar.gz -C /usr/local/bin/ tkn
tkn version
```

---

## 6. Fase 3 — Tasks e publicação como Task Bundles

### 6.1. O que é Task Bundle

Um artefato OCI (mesma tecnologia de imagem Docker) contendo o YAML da Task. Vantagens:

- **Versionamento imutável** via tags e digests
- **Reuso entre clusters** sem sincronizar CRDs
- **Consumo remoto** via `resolver: bundles`
- **Auditoria** — cada versão tem digest imutável

### 6.2. Preparar diretórios

```bash
kubectl create ns ci
mkdir -p ~/tekton-lab/tasks
cd ~/tekton-lab
```

### 6.3. Task: `git-clone`

`tasks/git-clone.yaml`:

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: git-clone
spec:
  description: Clona um repositório Git no workspace.
  params:
  - name: url
    type: string
  - name: revision
    type: string
    default: main
  workspaces:
  - name: output
  results:
  - name: commit
  steps:
  - name: clone
    image: alpine/git:2.43.0
    script: |
      #!/bin/sh
      set -eu
      cd $(workspaces.output.path)
      git clone $(params.url) .
      git checkout $(params.revision)
      COMMIT=$(git rev-parse HEAD)
      printf "%s" "$COMMIT" > $(results.commit.path)
```

### 6.4. Task: `maven-build`

`tasks/maven-build.yaml`:

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: maven-build
spec:
  description: Compila e empacota uma aplicação Java com Maven.
  params:
  - name: goals
    type: string
    default: "clean package -DskipTests"
  workspaces:
  - name: source
  steps:
  - name: build
    image: maven:3.9-eclipse-temurin-17
    workingDir: $(workspaces.source.path)
    script: |
      #!/bin/sh
      set -eu
      mvn $(params.goals)
      ls -lh target/*.jar 2>/dev/null || echo "Nenhum JAR encontrado"
```

### 6.5. Task: `kaniko-build-push`

`tasks/kaniko.yaml`:

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: kaniko-build-push
spec:
  description: Constrói uma imagem com Kaniko e envia para o registry.
  params:
  - name: image
    type: string
  - name: dockerfile
    type: string
    default: Dockerfile
  - name: context
    type: string
    default: ./
  workspaces:
  - name: source
  results:
  - name: image-digest
  steps:
  - name: build-and-push
    image: gcr.io/kaniko-project/executor:v1.23.2
    args:
    - --dockerfile=$(params.dockerfile)
    - --context=$(workspaces.source.path)/$(params.context)
    - --destination=$(params.image)
    - --insecure
    - --skip-tls-verify
    - --insecure-pull
    - --skip-tls-verify-pull
    - --digest-file=$(results.image-digest.path)
```

### 6.6. Publicar

```bash
REG=192.168.56.110:32000

tkn bundle push $REG/tekton/git-clone:v1         -f tasks/git-clone.yaml
tkn bundle push $REG/tekton/maven-build:v1       -f tasks/maven-build.yaml
tkn bundle push $REG/tekton/kaniko-build-push:v1 -f tasks/kaniko.yaml
```

### 6.7. Validar

```bash
curl -s http://192.168.56.110:32000/v2/_catalog
curl -s http://192.168.56.110:32000/v2/tekton/git-clone/tags/list
```

---

## 7. Fase 4 — Pipeline consumindo os Bundles

`pipeline.yaml`:

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: java-app-pipeline
  namespace: ci
spec:
  params:
  - name: repo-url
    type: string
  - name: revision
    type: string
    default: main
  - name: image
    type: string
  workspaces:
  - name: shared
  tasks:
  - name: clone
    taskRef:
      resolver: bundles
      params:
      - name: bundle
        value: registry.registry.svc.cluster.local:5000/tekton/git-clone:v1
      - name: name
        value: git-clone
      - name: kind
        value: task
    params:
    - name: url
      value: $(params.repo-url)
    - name: revision
      value: $(params.revision)
    workspaces:
    - name: output
      workspace: shared

  - name: build
    runAfter: [clone]
    taskRef:
      resolver: bundles
      params:
      - name: bundle
        value: registry.registry.svc.cluster.local:5000/tekton/maven-build:v1
      - name: name
        value: maven-build
      - name: kind
        value: task
    workspaces:
    - name: source
      workspace: shared

  - name: image
    runAfter: [build]
    taskRef:
      resolver: bundles
      params:
      - name: bundle
        value: registry.registry.svc.cluster.local:5000/tekton/kaniko-build-push:v1
      - name: name
        value: kaniko-build-push
      - name: kind
        value: task
    params:
    - name: image
      value: $(params.image)
    workspaces:
    - name: source
      workspace: shared
```

```bash
kubectl apply -f pipeline.yaml
kubectl -n ci get pipeline
```

---

## 8. Fase 5 — GitLab Community via Docker Compose

### 8.1. Descobrir IP do host na rede das VMs

```bash
ip -4 addr show | grep 192.168
```

Identifique a interface que está na mesma sub-rede das VMs — normalmente `virbr1` com IP `192.168.56.1`.

### 8.2. Estrutura

```bash
mkdir -p ~/gitlab-lab/{config,logs,data}
cd ~/gitlab-lab
```

### 8.3. `docker-compose.yml` (com network_mode: host)

Este ponto foi **crítico**: sem `network_mode: host`, o container do GitLab (na rede Docker 172.18.0.0/16) não consegue rotear pra 192.168.56.0/24.

```yaml
services:
  gitlab:
    image: gitlab/gitlab-ce:latest
    container_name: gitlab
    restart: unless-stopped
    hostname: gitlab.local
    network_mode: host
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://192.168.56.1:8929'
        nginx['listen_port'] = 8929
        gitlab_rails['gitlab_shell_ssh_port'] = 2224
        puma['worker_processes'] = 2
        sidekiq['max_concurrency'] = 10
        prometheus_monitoring['enable'] = false
    volumes:
      - ./config:/etc/gitlab
      - ./logs:/var/log/gitlab
      - ./data:/var/opt/gitlab
    shm_size: 256m
```

### 8.4. Subir

```bash
docker compose up -d
docker compose logs -f gitlab
```

Aguarde `gitlab Reconfigured!` (3–8 minutos).

### 8.5. Senha inicial

```bash
docker exec gitlab cat /etc/gitlab/initial_root_password | grep Password:
```

Login: `root`. Trocar a senha ao entrar.

### 8.6. **CRÍTICO** — Liberar Outbound requests para redes locais

Por segurança, o GitLab bloqueia webhooks para redes privadas por default:

1. **Admin Area → Settings → Network → Outbound requests**
2. Marcar:
   - ☑ Allow requests to the local network from webhooks and integrations
   - ☑ Allow requests to the local network from system hooks
3. **Save changes**

Sem isso, o GitLab recusa a URL do webhook com "Invalid url given".

---

## 9. Fase 6 — App Java de exemplo

```bash
mkdir -p ~/java-app-demo/src/main/java/com/example
cd ~/java-app-demo
```

**`pom.xml`:**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
    <modelVersion>4.0.0</modelVersion>
    <groupId>com.example</groupId>
    <artifactId>demo-app</artifactId>
    <version>1.0.0</version>
    <packaging>jar</packaging>
    <properties>
        <maven.compiler.source>17</maven.compiler.source>
        <maven.compiler.target>17</maven.compiler.target>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    </properties>
    <build>
        <finalName>demo-app</finalName>
        <plugins>
            <plugin>
                <groupId>org.apache.maven.plugins</groupId>
                <artifactId>maven-jar-plugin</artifactId>
                <version>3.4.1</version>
                <configuration>
                    <archive>
                        <manifest>
                            <mainClass>com.example.App</mainClass>
                        </manifest>
                    </archive>
                </configuration>
            </plugin>
        </plugins>
    </build>
</project>
```

**`src/main/java/com/example/App.java`:**

```java
package com.example;

public class App {
    public static void main(String[] args) {
        System.out.println("Hello from Tekton pipeline!");
    }
}
```

**`Dockerfile`:**

```dockerfile
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY target/demo-app.jar app.jar
ENTRYPOINT ["java", "-jar", "app.jar"]
```

**`.gitignore`:**

```
target/
*.class
.idea/
.vscode/
```

Enviar:

```bash
git init
git add .
git commit -m "Initial commit"
git remote add origin http://192.168.56.1:8929/root/java-app.git
git push -u origin main
```

---

## 10. Fase 7 — Triggers e webhook do GitLab

### 10.1. RBAC — precisa das DUAS bindings

```yaml
# triggers-rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tekton-triggers-sa
  namespace: ci
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tekton-triggers-eventlistener-binding
  namespace: ci
subjects:
- kind: ServiceAccount
  name: tekton-triggers-sa
  namespace: ci
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tekton-triggers-eventlistener-roles
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: tekton-triggers-sa-cluster
subjects:
- kind: ServiceAccount
  name: tekton-triggers-sa
  namespace: ci
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tekton-triggers-eventlistener-clusterroles
```

```bash
kubectl apply -f triggers-rbac.yaml
```

### 10.2. Secret do webhook

```bash
kubectl -n ci create secret generic gitlab-webhook-secret \
  --from-literal=secretToken='UM_TOKEN_FORTE_ALEATORIO'
```

Guarde exatamente esse valor — vai colar na UI do GitLab.

### 10.3. TriggerBinding, TriggerTemplate, Trigger, EventListener

```yaml
# triggers.yaml
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
---
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
  resourcetemplates:
  - apiVersion: tekton.dev/v1
    kind: PipelineRun
    metadata:
      generateName: java-app-run-
    spec:
      pipelineRef:
        name: java-app-pipeline
      params:
      - name: repo-url
        value: $(tt.params.repo-url)
      - name: revision
        value: $(tt.params.revision)
      - name: image
        value: registry.registry.svc.cluster.local:5000/apps/demo-app:$(tt.params.short-sha)
      workspaces:
      - name: shared
        volumeClaimTemplate:
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 2Gi
---
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
  bindings:
  - ref: gitlab-push-binding
  template:
    ref: java-app-template
---
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
```

```bash
kubectl apply -f triggers.yaml
kubectl -n ci get pods -l eventlistener=gitlab-listener -w
```

### 10.4. Cadastrar webhook no GitLab

Na UI do projeto, **Settings → Webhooks → Add new webhook**:

- **URL:** `http://192.168.56.110:32080`
- **Secret Token:** o mesmo valor do secret `gitlab-webhook-secret`
- **Trigger:** ✓ Push events
- **Enable SSL verification:** ☐ desmarcado

### 10.5. Testar

Na tela do webhook, botão **Test → Push events**. Resposta esperada: `HTTP 202`.

---

## 11. Fase 8 — Autenticação Git no clone

Se o projeto está **Private**, o `git clone` falha com `could not read Username`. Duas soluções:

### 11.1. Opção A — Projeto Public (lab)

**Settings → General → Visibility** → **Public** → **Save changes**

### 11.2. Opção B — PAT + Basic Auth (produção)

Gerar PAT no GitLab (**Preferences → Access tokens**, scope `read_repository`).

```bash
kubectl -n ci create secret generic gitlab-basic-auth \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=root \
  --from-literal=password='<PAT>'

kubectl -n ci annotate secret gitlab-basic-auth \
  tekton.dev/git-0=http://192.168.56.1:8929

kubectl -n ci patch serviceaccount default \
  -p '{"secrets":[{"name":"gitlab-basic-auth"}]}'
```

A anotação `tekton.dev/git-0` diz ao Tekton "use esse secret quando clonar dessa URL". Sem ela, o secret existe mas não é aplicado.

---

## 12. Fase 9 — Tekton Dashboard

### Opção 1 — Port-forward rápido

```bash
kubectl -n tekton-pipelines port-forward --address 0.0.0.0 \
  svc/tekton-dashboard 9097:9097
```

Acesso: `http://192.168.56.110:9097`

### Opção 2 — NodePort permanente

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: tekton-dashboard-np
  namespace: tekton-pipelines
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: dashboard
    app.kubernetes.io/part-of: tekton-dashboard
  ports:
  - port: 9097
    targetPort: 9097
    nodePort: 32097
EOF
```

Acesso: `http://192.168.56.110:32097`

O Dashboard mostra:
- **PipelineRuns** — histórico e status
- **TaskRuns** — cada task individual com logs
- **Pipelines** — definições
- **EventListeners** — status dos EL configurados
- Grafo visual de cada run com logs em tempo real
- Botão **Rerun** pra disparar novamente

---

## 13. Diagramas e troubleshooting

- Prompts para gerar diagramas: [docs/06-diagramas-prompts.md](06-diagramas-prompts.md)
- Problemas conhecidos desta fase: [docs/05-troubleshooting.md](05-troubleshooting.md)

---

## Referências

- [Tekton Pipelines](https://tekton.dev/docs/pipelines/)
- [Tekton Triggers](https://tekton.dev/docs/triggers/)
- [Tekton Bundles Resolver](https://tekton.dev/docs/pipelines/bundle-resolver/)
- [k3s registries.yaml](https://docs.k3s.io/installation/private-registry)
- [Kaniko](https://github.com/GoogleContainerTools/kaniko)
- [GitLab CE Docker](https://docs.gitlab.com/ee/install/docker.html)
- [GitLab Webhooks](https://docs.gitlab.com/ee/user/project/integrations/webhooks.html)

