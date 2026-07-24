# Template — Criar Namespace para Nova Aplicação Java

Template pronto para copiar/colar: cria o namespace, RBAC e secrets de uma **nova aplicação Java/Maven** (`backend-*`) na plataforma multi-tenant já existente. É a versão "preencha as variáveis" do playbook completo em [docs/02-arquitetura-multitenant.md §12](02-arquitetura-multitenant.md#12--playbook-adicionar-uma-nova-aplicação).

> Só cria coisas no **namespace do projeto** (`proj-<repo>`). Não toca no namespace `ci` — o Pipeline `java-app-pipeline` já existe e é compartilhado por todas as apps Java.

---

## 0. Pré-requisitos

```
[ ] Plataforma ci já rodando (kubectl -n ci get pipeline java-app-pipeline)
[ ] GitLab acessível
[ ] kubectl apontando pro cluster certo (kubectl config current-context)
```

---

## 1. Variáveis do template

Defina estas variáveis **antes** de rodar qualquer comando. É a única parte manual — o resto é copiar e colar.

| Variável | Descrição | Exemplo |
|---|---|---|
| `APP_NAME` | Nome curto da aplicação, sem prefixo | `payments` |
| `REPO_NAME` | `backend-<APP_NAME>` (prefixo obrigatório p/ o CEL rotear pro pipeline Java) | `backend-payments` |
| `NAMESPACE` | `proj-<REPO_NAME>` | `proj-backend-payments` |
| `GITLAB_URL` | Host do GitLab | `http://192.168.0.13:8929` |
| `GITLAB_USER` | Usuário dono do PAT | `root` |
| `PAT` | Personal Access Token (scope `read_repository`) gerado no Passo 2 | `glpat-xxxxxxxxxxxx` |

Exporte tudo no terminal (ajuste os valores):

```bash
export APP_NAME="payments"
export REPO_NAME="backend-${APP_NAME}"
export NAMESPACE="proj-${REPO_NAME}"
export GITLAB_URL="http://192.168.0.13:8929"
export GITLAB_USER="root"
export PAT="cole-o-pat-aqui"
```

---

## 2. Criar o projeto no GitLab e gerar o PAT

Manual, via UI (não dá pra automatizar sem a API do GitLab):

1. **+ → New project → Create blank project**
2. **Project name:** `${REPO_NAME}` (ex.: `backend-payments`) — **o prefixo `backend-` é obrigatório**
3. **Visibility Level:** `Internal`
4. **Initialize repository with a README:** desmarcar
5. **Create project**
6. Avatar → **Preferences → Access tokens → Add new token**
   - **Name:** `tekton-${REPO_NAME}`
   - **Scopes:** `read_repository`
   - **Create** → copie o token para a variável `PAT` acima (só aparece uma vez)

---

## 3. Provisionar namespace, secret e ServiceAccount

Três formas equivalentes de criar os mesmos recursos (namespace `proj-<repo>`, Secret `gitlab-basic-auth`, ServiceAccount `pipeline-runner`). **Helmfile é a recomendada** a partir do Épico 5 (Sprint 6) — as outras duas continuam funcionando e são úteis para entender o que está por baixo.

### 3a. Via Helmfile (recomendado)

Cada projeto é um bloco de release em [`helmfile.yaml.gotmpl`](../helmfile.yaml.gotmpl), reaproveitando o chart [`charts/tekton-project`](../charts/tekton-project). Adicionar um projeto novo = adicionar um bloco no arquivo (ver §6 de [docs/roadmap-helm.md](roadmap-helm.md) para o schema completo, e ADR-04 lá dentro para o porquê de uma release por projeto em vez de um loop no chart).

1. Abra `helmfile.yaml.gotmpl` e adicione um bloco em `releases:` — substitua `backend-payments` e `PAT_BACKEND_PAYMENTS` pelo `$REPO_NAME` e por uma env var equivalente para a sua app (o arquivo é YAML puro, não faz `envsubst`; escreva os valores literais):

   ```yaml
     - name: proj-backend-payments
       chart: ./charts/tekton-project
       values:
         - values-lab.yaml
       set:
         - name: project.name
           value: backend-payments
         - name: project.stack
           value: java
         - name: project.gitlabPAT
           value: '{{ requiredEnv "PAT_BACKEND_PAYMENTS" }}'
   ```

2. Exporte o PAT na variável referenciada acima (**nunca commitar** o PAT — ver ADR-03 em `docs/roadmap-helm.md`):

   ```bash
   export PAT_BACKEND_PAYMENTS="cole-o-pat-aqui"
   ```

3. Aplique só esse projeto:

   ```bash
   helmfile -l name=proj-backend-payments apply
   ```

   `helm` não está instalado no host deste lab — rode via Docker se preferir não instalar `helmfile`/`helm` localmente:

   ```bash
   docker run --rm -v "$PWD":/data -w /data \
     -e PAT_BACKEND_PAYMENTS \
     -v ~/.kube:/root/.kube \
     --entrypoint helmfile ghcr.io/helmfile/helmfile:latest \
     -l name=proj-backend-payments apply
   ```

Para remover um projeto: `helmfile -l name=proj-backend-payments destroy`.

### 3b. Via script (`scripts/onboarding/new-app.sh`)

> 🔧 Este bloco equivale a `PAT=<seu-pat> ./scripts/onboarding/new-app.sh backend ${APP_NAME}` ([`scripts/onboarding/new-app.sh`](../scripts/onboarding/new-app.sh)). O script cobre as mesmas variáveis do passo 1.

### 3c. Manual, comando a comando

Com as variáveis do passo 1 exportadas, rode o bloco inteiro de uma vez:

```bash
# Namespace com labels para facilitar queries futuras
kubectl create ns "$NAMESPACE"
kubectl label ns "$NAMESPACE" \
  tekton.dev/project=true \
  app="$REPO_NAME" \
  stack=java

# Secret com o PAT (usado pela Task git-clone)
kubectl -n "$NAMESPACE" create secret generic gitlab-basic-auth \
  --type=kubernetes.io/basic-auth \
  --from-literal=username="$GITLAB_USER" \
  --from-literal=password="$PAT"

# Anotação: "use esse secret quando clonar dessa URL"
kubectl -n "$NAMESPACE" annotate secret gitlab-basic-auth \
  tekton.dev/git-0="$GITLAB_URL"

# ServiceAccount fixo pipeline-runner com o secret anexado
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pipeline-runner
  namespace: ${NAMESPACE}
secrets:
- name: gitlab-basic-auth
EOF
```

**Por que os nomes `pipeline-runner` e `gitlab-basic-auth` são fixos:** o `TriggerTemplate` do namespace `ci` referencia esses nomes literalmente. Renomear quebra o clone (a SA usada cairia para `default`, sem o secret).

**Validação:**

```bash
kubectl -n "$NAMESPACE" get sa,secret
# esperado: sa/pipeline-runner, sa/default, secret/gitlab-basic-auth
```

---

## 4. Cadastrar o webhook no GitLab

Obter o token compartilhado do webhook:

```bash
kubectl -n ci get secret gitlab-webhook-secret \
  -o jsonpath='{.data.secretToken}' | base64 -d && echo
```

No projeto GitLab (`${REPO_NAME}`) → **Settings → Webhooks → Add new webhook**:

| Campo | Valor |
|---|---|
| URL | `http://192.168.56.110:32080` |
| Secret Token | token obtido acima |
| Trigger | ✓ Push events |
| Enable SSL verification | ☐ desmarcar |

Clique **Add webhook** e depois **Test → Push events** — esperado: `HTTP 202`.

---

## 5. Dockerfile na raiz do repo (obrigatório)

Sem `Dockerfile`, o Kaniko não tem o que buildar. Template mínimo para Java/Maven:

```
backend-payments/
├── pom.xml
├── Dockerfile
└── src/main/java/...
```

```dockerfile
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY target/*.jar app.jar
ENTRYPOINT ["java", "-jar", "app.jar"]
```

> Ajuste a versão do JRE (`17-jre-alpine`) conforme a versão do projeto. O `pom.xml` deve gerar um `.jar` executável em `target/`.

---

## 6. Push do código

```bash
cd "$REPO_NAME"
git init
git add .
git commit -m "Initial commit"
git remote add origin "${GITLAB_URL}/${GITLAB_USER}/${REPO_NAME}.git"
git push -u origin main
```

O push dispara o webhook → o CEL do EventListener detecta o prefixo `backend-` → roteia para `java-app-pipeline` → cria o `PipelineRun` em `${NAMESPACE}`.

---

## 7. Acompanhar a primeira execução

```bash
# Terminal 1 — log do EL (ver o CEL calculando o roteamento)
kubectl -n ci logs -l eventlistener=gitlab-listener -f --timestamps

# Terminal 2 — status do run
kubectl -n "$NAMESPACE" get pipelinerun -w

# Terminal 3 — log do pipeline (depois que o run aparecer)
tkn pipelinerun logs -f -n "$NAMESPACE" --last

# Verificar imagem publicada no registry
curl -s "http://192.168.56.110:32000/v2/apps/${REPO_NAME}/tags/list"
```

---

## 8. Checklist final

```
[ ] Variáveis exportadas (APP_NAME, REPO_NAME, NAMESPACE, GITLAB_URL, PAT)
[ ] Projeto criado no GitLab com prefixo backend-
[ ] PAT gerado (scope read_repository)
[ ] Namespace proj-<repo> criado e labeled
[ ] Secret gitlab-basic-auth criado + anotação tekton.dev/git-0
[ ] ServiceAccount pipeline-runner criada com o secret anexado
[ ] Webhook cadastrado no GitLab (URL + token) e testado (202)
[ ] Dockerfile na raiz do repo
[ ] git push feito
[ ] PipelineRun apareceu em proj-<repo>
[ ] Imagem publicada em apps/<repo>:<sha> no registry
```

Tempo estimado: ~5 minutos (fora o tempo de build do Maven/Kaniko).

---

## 9. Se algo der errado

| Sintoma | Onde olhar |
|---|---|
| Webhook retorna erro diferente de 202 | Token errado ou EL fora do ar — ver [docs/04-ci-operacional.md §8](04-ci-operacional.md#8--playbook-recuperar-o-ci-após-incidente) |
| PipelineRun nunca é criado | Log do EL mostra `forbidden`? RBAC do `ci` — ver [docs/04-ci-operacional.md §3](04-ci-operacional.md#3-mapa-mental-quem-depende-de-quem) |
| PipelineRun criado mas falha no clone | Secret `gitlab-basic-auth` ou anotação `tekton.dev/git-0` erradas |
| Falha no Kaniko | Falta `Dockerfile` na raiz, ou `pom.xml` não gera `.jar` em `target/` |
| Lista completa de problemas conhecidos | [docs/05-troubleshooting.md](05-troubleshooting.md) |

---

## Referências

- [docs/02-arquitetura-multitenant.md](02-arquitetura-multitenant.md) — arquitetura completa e o playbook narrativo original
- [docs/04-ci-operacional.md](04-ci-operacional.md) — operação do namespace `ci`
- [docs/05-troubleshooting.md](05-troubleshooting.md) — problemas conhecidos
- [docs/roadmap-helm.md](roadmap-helm.md) — backlog da migração Helm, schema de `values-lab.yaml` e ADRs (ADR-03 secrets, ADR-04 Helmfile)
- [charts/tekton-project](../charts/tekton-project) — chart usado pelo Helmfile (§3a)
