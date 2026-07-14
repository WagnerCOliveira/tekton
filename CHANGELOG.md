# Changelog

Todas as mudanças notáveis neste projeto serão documentadas aqui.
O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e este projeto adere a [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [Não lançado]

### Adicionado
- Estrutura consolidada de documentação: `docs/` (satélites numerados), `docs/decisions/` (ADRs), `scripts/{setup,ops,onboarding}/`, `yaml/{ci,projects,tasks}/`, `CHANGELOG.md` — `[Claude Code - 2026-07-12]`
- `scripts/ops/fix-pipelinerun-namespace.sh` — corrige e migra Triggers single-tenant para o Padrão B completo (namespace dinâmico, SA `pipeline-runner`, `app-template` genérico com CEL `filter`+overlays) — `[Claude Code - 2026-07-12]`
- `charts/tekton-registry` — primeiro chart Helm da migração (Épico 1, Sprint 2 de `docs/roadmap-helm.md`): Namespace, PVC, Deployment com liveness/readiness probes e Service NodePort, com `storage.size`, `service.nodePort`, `image.repository`/`tag` e `config.deleteEnabled` parametrizados em `values.yaml`; valores default preservam o comportamento atual de `yaml/ci/registry.yaml`. Validado com `helm lint` e `helm template` (`alpine/helm:3.14.4`); HLM-04 a HLM-07 concluídas — `[Claude Code - 2026-07-13]`
- `charts/tekton-platform` — segundo chart da migração (Épico 2, Sprint 3): Namespace `ci`, RBAC completo do EventListener (ServiceAccount + RoleBinding + 2 ClusterRoleBindings), Secret `gitlab-webhook-secret` com geração automática (`randAlphaNum 40`) que preserva o token existente em upgrades via `lookup`, ConfigMap `cluster-resolver-config` e patch dos feature flags do Tekton core via Job com Helm hook `pre-install,pre-upgrade`. Escopo desta versão: RBAC e Secrets — Pipelines/Triggers/EventListener entram no Épico 4. Validado com `helm lint` e `helm template`, incluindo overrides de namespace, token explícito e `allowedNamespaces`; HLM-08 a HLM-11 concluídas — `[Claude Code - 2026-07-13]`
- `charts/tekton-bundles` — terceiro chart da migração (Épico 3, Sprint 4): ConfigMaps com o YAML de cada Task (`git-clone`, `maven-build`, `node-build`, `kaniko-build-push`) e Jobs Helm hook `pre-install,pre-upgrade` que publicam os Task Bundles no registry interno via `tkn bundle push`, idempotentes (checam `/v2/<task>/tags/list` antes de publicar — nunca sobrescrevem tag em uso, ver ADR-003). Tag e imagem base de cada bundle parametrizadas em `values.yaml` (`bundles.<nome>.tag`/`.image`); `registry.host` default `192.168.56.110:32000` preserva o comportamento de `scripts/setup/05-publish-task-bundles.sh`. Validado com `helm lint` e `helm template` (`alpine/helm:3.14.4`); HLM-12 a HLM-15 concluídas — `[Claude Code - 2026-07-14]`
- `charts/tekton-platform` — Épico 4 (Sprint 5): Pipelines por stack via `range .Values.platform.stacks` (`java-app-pipeline`, `node-app-pipeline`), TriggerTemplate/TriggerBinding genéricos (sem stack hardcoded), Trigger com CEL (`filter` + overlay `pipeline-name`) gerado dinamicamente a partir de `platform.stacks` — adicionar uma stack no values regenera o roteamento sem tocar em template —, EventListener + Service NodePort, e Helm test (`helm test`) validando o smoke test do webhook (POST com token correto → HTTP 202). Saída de `helm template` idêntica byte a byte aos manifestos manuais equivalentes em `yaml/ci/pipelines/` e `yaml/ci/triggers/`. Validado com `helm lint --strict` e `helm template` (`alpine/helm:3.14.4`), incluindo teste manual com uma terceira stack fictícia; HLM-17 a HLM-21 concluídas — `[Claude Code - 2026-07-14]`

### Alterado
- `troubleshooting.md` §7.5 — nova entrada documentando o sintoma "PipelineRun cai no namespace `ci` em vez de `proj-*`", incluindo o aviso sobre correção parcial que reintroduz roteamento hardcoded — `[Claude Code - 2026-07-12]`

### Corrigido
### Removido

---

## [1.3.0] - 2026-07-11

### Adicionado
- `tekton-template-novo-projeto-java.md` — template copia-e-cola para onboarding de nova aplicação Java/Maven (`backend-*`), com variáveis exportáveis e checklist final

---

## [1.2.0] - 2026-07-09

### Alterado
- Diagramas ASCII substituídos por imagens PNG (geradas via Gemini/Imagen a partir dos prompts em `gemini-prompts.md`) em `README.md`, `tekton-lab-setup.md`, `tekton-multitenant.md` e `tekton-ci-playbook.md`

---

## [1.1.0] - 2026-07-06

### Adicionado
- `README.md` como índice mestre da documentação (arquitetura, mapa de docs, convenções, componentes)
- `tekton-multitenant.md` — consolidação final da arquitetura Padrão B multi-tenant e dos playbooks de onboarding, substituindo os dois rascunhos abaixo
- `troubleshooting.md` consolidado por categoria (8 categorias, problemas de instalação a multi-tenant/CEL)
- `gemini-prompts.md` — todos os prompts de geração de diagrama centralizados
- `helm-backlog.md` — backlog de migração para Helm (38 histórias, 8 sprints, 5 ADRs internos de escopo Helm)
- 12 imagens de arquitetura em `imagens/`

### Removido
- `tekton-passo1-multitenant.md` e `tekton-multitenant-e-playbook.md` marcados como **supersedidos** (conteúdo consolidado em `tekton-multitenant.md`); mantidos apenas como referência histórica até esta consolidação, quando foram movidos para `_workspace/pending-review/` — ver [ADR-001](docs/decisions/ADR-001-padrao-b-multitenant.md)

---

## [1.0.0] - 2026-07-05

### Adicionado
- `tekton-lab-setup.md` — infraestrutura base: k3s (1 server + 2 agents), Tekton Pipelines/Triggers/Dashboard, registry Docker interno, Task Bundles (`git-clone`, `maven-build`, `kaniko-build-push`), GitLab CE via Docker Compose, primeira pipeline Java end-to-end
- `tekton-ci-playbook.md` — playbook operacional do namespace `ci`, já direcionado à arquitetura Padrão B multi-tenant (2026-07-05 (aproximado); o conteúdo do primeiro commit já reflete o `app-template` genérico e o RBAC cross-namespace, então parte deste playbook foi provavelmente escrito em conjunto com a decisão do Padrão B, não estritamente antes dela)
- `tekton-passo1-multitenant.md`, `tekton-multitenant-e-playbook.md` — rascunhos da evolução para arquitetura multi-tenant (posteriormente consolidados e supersedidos em 1.1.0)

---

## Como manter este arquivo

- Toda mudança em Pipelines, Tasks ou Triggers no `ci` gera uma entrada
- Onboarding de nova app NÃO gera entrada aqui (é operação corrente)
- Correções críticas de bug em produção geram bump de PATCH (X.Y.Z+1)
- Novos padrões/convenções geram bump de MINOR (X.Y+1.0)
- Mudança que quebra compatibilidade com apps existentes gera bump de MAJOR (X+1.0.0)
