# Playbook — Bootstrap da Plataforma via Helm

Guia único para subir a plataforma inteira (`charts/tekton-registry`, `charts/tekton-platform`, `charts/tekton-bundles`) do zero, na ordem certa, com os comandos batendo com o `values.yaml` atual de cada chart. Onboarding de uma app nova (`charts/tekton-project`) **não** entra aqui — ver [docs/03-onboarding-app-java.md](03-onboarding-app-java.md).

> Esta documentação não existia até agora — os 4 charts foram migrados em sprints separados (ver [docs/roadmap-helm.md](roadmap-helm.md), histórico) sem um playbook de bootstrap consolidado. `docs/roadmap-helm.md` §2 tem um exemplo de instalação, mas é do planejamento original: cita um chart `tekton-lab` (umbrella) que nunca foi criado e usa `-f values-lab.yaml` em charts que não consomem esse arquivo (só `charts/tekton-project`, via Helmfile, usa). Este documento é a versão atual e testada (`helm lint`/`helm template`).

---

## Sumário

1. [Pré-requisitos (fora do escopo dos charts)](#1-pré-requisitos-fora-do-escopo-dos-charts)
2. [`helm` via Docker](#2-helm-via-docker)
3. [Passo 1 — `tekton-registry`](#3-passo-1--tekton-registry)
4. [Passo 2 — `tekton-platform`](#4-passo-2--tekton-platform)
5. [Passo 3 — `tekton-bundles`](#5-passo-3--tekton-bundles)
6. [Passo 4 — Dashboard (se ainda não instalado)](#6-passo-4--dashboard-se-ainda-não-instalado)
7. [Passo 5 — Onboardar a primeira app](#7-passo-5--onboardar-a-primeira-app)
8. [Validação de ponta a ponta](#8-validação-de-ponta-a-ponta)
9. [Ordem resumida](#9-ordem-resumida)

---

## 1. Pré-requisitos (fora do escopo dos charts)

Por decisão de arquitetura (ADR-01 em `docs/roadmap-helm.md`), a instalação do **Tekton core** (Pipelines, Triggers, Interceptors, Dashboard) **não** foi Helm-ificada — continua via `kubectl apply` nos manifestos oficiais upstream, como em [docs/01-infraestrutura-base.md §4](01-infraestrutura-base.md#4-fase-1--instalação-do-tekton). Isso precisa estar pronto **antes** de instalar qualquer chart deste repositório:

```
[ ] Tekton Pipelines instalado (kubectl get pods -n tekton-pipelines)
[ ] Tekton Triggers + Interceptors instalados
[ ] Tekton Dashboard instalado (opcional nesta etapa — só é exposto no Passo 4)
[ ] k3s configurado para aceitar o registry inseguro nos nós (docs/01 §5.3) —
    necessário para push/pull de imagens, não bloqueia os `helm install` em si
[ ] kubectl apontando para o cluster certo (kubectl config current-context)
```

`charts/tekton-platform` referencia `ClusterRole`s criados pela instalação do Tekton Triggers (`tekton-triggers-eventlistener-roles` etc.) e faz `kubectl patch` no `ConfigMap feature-flags` do namespace `tekton-pipelines` — sem o Tekton core já instalado, o Job de feature flags falha.

---

## 2. `helm` via Docker

`helm` não está instalado no host deste lab (mesma observação em `docs/04-ci-operacional.md` §6a). Todos os comandos abaixo usam `alpine/helm:3.14.4` via Docker:

```bash
alias helmd='docker run --rm -v "$PWD":/data -w /data -v ~/.kube:/root/.kube alpine/helm:3.14.4'
```

(substitua `helmd` por `helm` diretamente se preferir instalar o binário)

---

## 3. Passo 1 — `tekton-registry`

Não depende de nenhum outro chart. Cria o namespace `registry`, PVC, Deployment e Service NodePort (`32000` por default).

```bash
helmd upgrade --install tekton-registry ./charts/tekton-registry
```

**Validar:**

```bash
kubectl -n registry get pods,svc,pvc
IP_SERVER=$(kubectl get node k3s-server -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
curl -sf http://$IP_SERVER:32000/v2/ && echo   # espera "{}"
```

---

## 4. Passo 2 — `tekton-platform`

Depende do **Tekton core já instalado** (Passo 0). Cria o namespace `ci`, RBAC do EventListener, Secret do webhook, patch dos feature flags, Pipelines por stack (`java-app-pipeline`, `node-app-pipeline`), Triggers/EventListener e o Service NodePort do Dashboard.

```bash
helmd upgrade --install tekton-platform ./charts/tekton-platform
```

`platform.taskBundleRegistry` (default `registry.registry.svc.cluster.local:5000/tekton`) precisa bater com `registry.host`/`repository` do `charts/tekton-bundles` (Passo 3) — já vêm consistentes nos defaults dos dois charts; só reconferir se algum dos dois valores for sobrescrito.

**Validar:**

```bash
kubectl -n ci get pipeline,trigger,eventlistener,pods
kubectl -n tekton-pipelines get cm feature-flags -o yaml | grep -E "enable-bundles-resolver|enable-cluster-resolver"
```

---

## 5. Passo 3 — `tekton-bundles`

Depende do namespace `ci` já existir (Passo 2) **e** do registry já estar de pé e alcançável em `registry.host` (Passo 1) — o Job de publicação roda `tkn bundle push` contra `192.168.56.110:32000` (IP:NodePort, não o DNS interno — ver ADR-005 em `docs/roadmap-helm.md`).

```bash
helmd upgrade --install tekton-bundles ./charts/tekton-bundles
```

Os Jobs (`pre-install,pre-upgrade`) são idempotentes: só publicam uma tag se ela ainda não existir no registry (ADR-003 — nunca sobrescrevem tag em uso).

**Validar:**

```bash
kubectl -n ci get jobs -l app.kubernetes.io/instance=tekton-bundles
curl -s http://192.168.56.110:32000/v2/tekton/git-clone/tags/list
curl -s http://192.168.56.110:32000/v2/tekton/maven-build/tags/list
curl -s http://192.168.56.110:32000/v2/tekton/kaniko-build-push/tags/list
```

---

## 6. Passo 4 — Dashboard (se ainda não instalado)

`charts/tekton-platform` (Passo 2) já criou o Service NodePort `tekton-dashboard-np` (porta `32097`), mas o Deployment do Dashboard em si é instalado à parte (fora do escopo dos charts, mesma decisão do Passo 0):

```bash
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/latest/release.yaml
```

**Validar:** `http://<IP_SERVER>:32097` abre a UI do Dashboard.

---

## 7. Passo 5 — Onboardar a primeira app

Com os 3 charts de plataforma no ar, cada app usa `charts/tekton-project` via Helmfile — **não** repita esse passo aqui, siga [docs/03-onboarding-app-java.md §3a](03-onboarding-app-java.md#3a-via-helmfile-recomendado) (ou o equivalente Node) do zero até o primeiro `PipelineRun`.

---

## 8. Validação de ponta a ponta

Depois do onboarding de uma app de teste (Passo 5), confirme o ciclo completo:

```bash
kubectl -n proj-<repo> get pipelinerun -w
tkn pipelinerun logs -f -n proj-<repo> --last
curl -s http://192.168.56.110:32000/v2/apps/<repo>/tags/list
```

Se algo falhar, comece por [docs/05-troubleshooting.md](05-troubleshooting.md).

---

## 9. Ordem resumida

```
0. kubectl apply — Tekton core (Pipelines, Triggers, Interceptors)      [fora dos charts]
1. helm install  — tekton-registry                                     [independente]
2. helm install  — tekton-platform         (precisa de 0)
3. helm install  — tekton-bundles          (precisa de 1 e 2)
4. kubectl apply — Dashboard                                           [fora dos charts, opcional aqui]
5. helmfile apply — tekton-project por app (precisa de 2 e 3)          [docs/03]
```

---

## Referências

- [docs/01-infraestrutura-base.md](01-infraestrutura-base.md) — instalação do Tekton core e do que os charts substituem
- [docs/03-onboarding-app-java.md](03-onboarding-app-java.md) — onboarding de app via `charts/tekton-project`
- [docs/04-ci-operacional.md §6a](04-ci-operacional.md#6a-via-helm-recomendado--hlm-16) — upgrade de Task Bundle / Pipeline já em produção (não é bootstrap)
- [docs/roadmap-helm.md](roadmap-helm.md) — histórico do planejamento da migração, ADRs (ADR-01 a ADR-05)
- [docs/decisions/](decisions/) — ADRs completos
