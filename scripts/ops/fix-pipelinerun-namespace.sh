#!/usr/bin/env bash
# Fix: PipelineRun caindo no namespace `ci` em vez do namespace do projeto (proj-*)
#
# ANÁLISE ORIGINAL DO BUG:
# O Trigger/TriggerBinding/TriggerTemplate atualmente aplicados no cluster (ci)
# ainda são a versão single-tenant original (ver tekton-lab-setup.md):
#   - TriggerBinding (gitlab-push-binding) só extrai repo-url/revision/short-sha,
#     sem calcular o namespace do projeto.
#   - Trigger (gitlab-push-trigger) só tem o interceptor `gitlab`, sem o `cel`
#     que calcularia target-namespace/repo-name/pipeline-name a partir de
#     body.project.name.
#   - TriggerTemplate (java-app-template) cria o PipelineRun sem `metadata.namespace`
#     -> cai no namespace do próprio EventListener (ci) -- é exatamente o bug.
#   - Também não define `taskRunTemplate.serviceAccountName`, por isso a SA usada
#     era `default` em vez de `pipeline-runner`.
#   - A imagem publicada estava fixa em "apps/demo-app", o que quebraria com
#     múltiplos projetos -- corrigido para usar o nome real do repo.
#
# CORREÇÃO DE ESCOPO (rev. 2): a primeira versão deste script apenas corrigia
# os sintomas acima mas recriava o TriggerTemplate com o nome antigo
# `java-app-template` e sem o overlay `pipeline-name`/`filter` do CEL. Isso
# reintroduzia a topologia single-tenant (um template por stack, hardcoded
# para java-app-pipeline) em vez de migrar para o Padrão B documentado em
# tekton-multitenant.md: um único `app-template` genérico + CEL decidindo
# target-namespace/repo-name/pipeline-name. Sem isso, um push em um repo
# `frontend-*` seria roteado (silenciosamente) para java-app-pipeline.
# Esta versão migra de fato para essa topologia.
#
# Confirmado no cluster (sessão anterior):
#   - Namespace proj-backend-java8-app já existe com SA pipeline-runner e
#     secret gitlab-basic-auth (onboarding já foi feito corretamente).
#   - enable-cluster-resolver estava desabilitado.
#   - ClusterRoleBinding tekton-triggers-sa-create-pipelinerun não existia.
#
# Este script:
#   1. Valida pré-condições (não assume, checa).
#   2. Faz backup dos recursos do `ci` antes de sobrescrever qualquer coisa.
#   3. Aplica as correções na ordem correta (Binding -> Template -> Trigger).
#   4. Migra TriggerTemplate/TriggerBinding/Trigger para o nome e o CEL
#      completo do Padrão B (app-template), evitando regressão em frontend-*.
#
# Rode como usuário com kubectl apontando pro cluster certo (confira com
# `kubectl config current-context`).

set -euo pipefail

NS_CI="ci"
PROJECT_NS="proj-backend-java8-app"
BACKUP_DIR="./backup-ci-$(date +%Y%m%d-%H%M%S)"

echo "== 0. Confirmando contexto do kubectl =="
kubectl config current-context
read -rp "Contexto correto? [enter para continuar, Ctrl+C para abortar] "

echo
echo "== 0.1. Pré-condições (falha rápido se algo estiver faltando) =="

fail=0
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  OK  - $desc"
  else
    echo "  FALTA - $desc"
    fail=1
  fi
}

check "namespace $NS_CI existe"            kubectl get ns "$NS_CI"
check "namespace $PROJECT_NS existe"        kubectl get ns "$PROJECT_NS"
check "SA pipeline-runner em $PROJECT_NS"   kubectl -n "$PROJECT_NS" get sa pipeline-runner
check "secret gitlab-basic-auth em $PROJECT_NS" kubectl -n "$PROJECT_NS" get secret gitlab-basic-auth
check "SA tekton-triggers-sa em $NS_CI"     kubectl -n "$NS_CI" get sa tekton-triggers-sa
check "secret gitlab-webhook-secret em $NS_CI" kubectl -n "$NS_CI" get secret gitlab-webhook-secret
check "pipeline java-app-pipeline em $NS_CI" kubectl -n "$NS_CI" get pipeline java-app-pipeline

if ! kubectl -n "$NS_CI" get pipeline node-app-pipeline >/dev/null 2>&1; then
  echo "  AVISO - pipeline node-app-pipeline não existe em $NS_CI."
  echo "          O CEL abaixo vai rotear repos frontend-* para node-app-pipeline;"
  echo "          se essa pipeline não existir, o push só vai falhar quando"
  echo "          alguém de fato empurrar código para um repo frontend-*."
  echo "          Não é bloqueante agora (só temos backend-java8-app), mas"
  echo "          crie node-app-pipeline antes de onboardar o primeiro frontend."
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "Pré-condições faltando acima. Corrija antes de continuar (veja"
  echo "tekton-ci-playbook.md, playbook 'Recuperar o ci após incidente')."
  exit 1
fi

echo
echo "== 0.2. Backup dos recursos do $NS_CI antes de sobrescrever =="
mkdir -p "$BACKUP_DIR"
for res in triggerbinding/gitlab-push-binding trigger/gitlab-push-trigger; do
  kind_name=${res%%/*}
  name=${res##*/}
  if kubectl -n "$NS_CI" get "$kind_name" "$name" >/dev/null 2>&1; then
    kubectl -n "$NS_CI" get "$kind_name" "$name" -o yaml > "$BACKUP_DIR/${kind_name}-${name}.yaml"
  fi
done
# TriggerTemplate antigo (nome single-tenant) e o novo nome, se já existir
for tt in java-app-template app-template; do
  if kubectl -n "$NS_CI" get triggertemplate "$tt" >/dev/null 2>&1; then
    kubectl -n "$NS_CI" get triggertemplate "$tt" -o yaml > "$BACKUP_DIR/triggertemplate-${tt}.yaml"
  fi
done
echo "Backup salvo em $BACKUP_DIR"

echo
echo "== 1. Habilitando o cluster resolver =="
kubectl -n tekton-pipelines patch cm feature-flags \
  --type merge -p '{"data":{"enable-cluster-resolver":"true"}}'

flag_value=$(kubectl -n tekton-pipelines get cm feature-flags -o jsonpath='{.data.enable-cluster-resolver}')
if [ "$flag_value" != "true" ]; then
  echo "ERRO: enable-cluster-resolver não ficou 'true' (valor atual: '$flag_value')."
  exit 1
fi
echo "enable-cluster-resolver = true (confirmado)"

if kubectl get ns tekton-pipelines-resolvers >/dev/null 2>&1; then
  echo "Namespace tekton-pipelines-resolvers encontrado, aplicando config..."
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

  echo "Aguardando pod do resolver ficar Ready..."
  if ! kubectl -n tekton-pipelines-resolvers wait --for=condition=Ready pod --all --timeout=60s; then
    echo "AVISO: pod do resolver não ficou Ready em 60s. Verifique antes de continuar:"
    echo "  kubectl -n tekton-pipelines-resolvers get pods"
    read -rp "Continuar mesmo assim? [enter para continuar, Ctrl+C para abortar] "
  fi
else
  echo "AVISO: namespace tekton-pipelines-resolvers não existe."
  echo "O cluster resolver pode não estar instalado. Pare aqui e verifique"
  echo "a instalação do Tekton Pipelines (feature de remote resolvers) antes"
  echo "de continuar -- os próximos passos vão falhar sem isso."
  read -rp "Continuar mesmo assim? [enter para continuar, Ctrl+C para abortar] "
fi

echo
echo "== 2. RBAC: permitir o EventListener criar PipelineRuns fora do ci =="
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

echo
echo "== 3. TriggerBinding: target-namespace, repo-name e pipeline-name =="
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

echo
echo "== 4. TriggerTemplate app-template: namespace dinâmico + SA pipeline-runner + resolver cluster =="
echo "   (substitui o antigo java-app-template -- ver nota de escopo no topo do script)"
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
      params:
      - name: repo-url
        value: $(tt.params.repo-url)
      - name: revision
        value: $(tt.params.revision)
      - name: image
        value: registry.registry.svc.cluster.local:5000/apps/$(tt.params.repo-name):$(tt.params.short-sha)
      pipelineRef:
        resolver: cluster
        params:
        - { name: kind, value: pipeline }
        - { name: name, value: $(tt.params.pipeline-name) }
        - { name: namespace, value: ci }
      workspaces:
      - name: shared
        volumeClaimTemplate:
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 2Gi
EOF

echo
echo "== 5. Trigger: interceptor cel completo (filter + overlays) apontando pro app-template =="
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

echo
echo "== 6. Reiniciando o pod do EventListener =="
kubectl -n ci delete pod -l eventlistener=gitlab-listener
echo "Aguardando novo pod ficar Ready..."
kubectl -n ci wait --for=condition=Ready pod -l eventlistener=gitlab-listener --timeout=120s
kubectl -n ci get pods -l eventlistener=gitlab-listener

echo
echo "== Pronto =="
echo "O TriggerTemplate antigo 'java-app-template' NÃO foi apagado automaticamente"
echo "(operação destrutiva). Depois de validar que o push abaixo funciona, remova-o:"
echo "  kubectl -n ci delete triggertemplate java-app-template"
echo
echo "Faça um push no repo backend-java8-app e acompanhe em dois terminais:"
echo "  kubectl -n ci logs -l eventlistener=gitlab-listener -f --timestamps"
echo "  kubectl -n proj-backend-java8-app get pipelinerun -w"
echo
echo "Se/quando existir um repo frontend-*, valide também que ele roteia para"
echo "node-app-pipeline (e não para java-app-pipeline) -- é a regressão que"
echo "esta versão do script evita."
