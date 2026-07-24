# Changelog

Todas as mudanças notáveis neste projeto serão documentadas aqui.
O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e este projeto adere a [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [Não lançado]

### Adicionado
- `docs/07-bootstrap-helm.md` — playbook consolidado de bootstrap da plataforma via Helm (`tekton-registry` → `tekton-platform` → `tekton-bundles`, na ordem certa, com pré-requisitos fora do escopo dos charts e comandos batendo com o `values.yaml` atual de cada chart); preenche lacuna deixada pela migração Helm, que não tinha um guia único de instalação do zero — `docs/roadmap-helm.md` §2 (exemplo do planejamento original, desatualizado: cita chart `tekton-lab` inexistente) agora aponta pra cá — `[Claude Code - 2026-07-24]`
- Estrutura consolidada de documentação: `docs/` (satélites numerados), `docs/decisions/` (ADRs), `scripts/{setup,ops,onboarding}/`, `yaml/{ci,projects,tasks}/`, `CHANGELOG.md` — `[Claude Code - 2026-07-12]`
- `scripts/ops/fix-pipelinerun-namespace.sh` — corrige e migra Triggers single-tenant para o Padrão B completo (namespace dinâmico, SA `pipeline-runner`, `app-template` genérico com CEL `filter`+overlays) — `[Claude Code - 2026-07-12]`
- `charts/tekton-registry` — primeiro chart Helm da migração (Épico 1, Sprint 2 de `docs/roadmap-helm.md`): Namespace, PVC, Deployment com liveness/readiness probes e Service NodePort, com `storage.size`, `service.nodePort`, `image.repository`/`tag` e `config.deleteEnabled` parametrizados em `values.yaml`; valores default preservam o comportamento atual de `yaml/ci/registry.yaml`. Validado com `helm lint` e `helm template` (`alpine/helm:3.14.4`); HLM-04 a HLM-07 concluídas — `[Claude Code - 2026-07-13]`
- `charts/tekton-platform` — segundo chart da migração (Épico 2, Sprint 3): Namespace `ci`, RBAC completo do EventListener (ServiceAccount + RoleBinding + 2 ClusterRoleBindings), Secret `gitlab-webhook-secret` com geração automática (`randAlphaNum 40`) que preserva o token existente em upgrades via `lookup`, ConfigMap `cluster-resolver-config` e patch dos feature flags do Tekton core via Job com Helm hook `pre-install,pre-upgrade`. Escopo desta versão: RBAC e Secrets — Pipelines/Triggers/EventListener entram no Épico 4. Validado com `helm lint` e `helm template`, incluindo overrides de namespace, token explícito e `allowedNamespaces`; HLM-08 a HLM-11 concluídas — `[Claude Code - 2026-07-13]`
- `charts/tekton-bundles` — terceiro chart da migração (Épico 3, Sprint 4): ConfigMaps com o YAML de cada Task (`git-clone`, `maven-build`, `node-build`, `kaniko-build-push`) e Jobs Helm hook `pre-install,pre-upgrade` que publicam os Task Bundles no registry interno via `tkn bundle push`, idempotentes (checam `/v2/<task>/tags/list` antes de publicar — nunca sobrescrevem tag em uso, ver ADR-003). Tag e imagem base de cada bundle parametrizadas em `values.yaml` (`bundles.<nome>.tag`/`.image`); `registry.host` default `192.168.56.110:32000` preserva o comportamento de `scripts/setup/05-publish-task-bundles.sh`. Validado com `helm lint` e `helm template` (`alpine/helm:3.14.4`); HLM-12 a HLM-15 concluídas — `[Claude Code - 2026-07-14]`
- `charts/tekton-platform` — Épico 4 (Sprint 5): Pipelines por stack via `range .Values.platform.stacks` (`java-app-pipeline`, `node-app-pipeline`), TriggerTemplate/TriggerBinding genéricos (sem stack hardcoded), Trigger com CEL (`filter` + overlay `pipeline-name`) gerado dinamicamente a partir de `platform.stacks` — adicionar uma stack no values regenera o roteamento sem tocar em template —, EventListener + Service NodePort, e Helm test (`helm test`) validando o smoke test do webhook (POST com token correto → HTTP 202). Saída de `helm template` idêntica byte a byte aos manifestos manuais equivalentes em `yaml/ci/pipelines/` e `yaml/ci/triggers/`. Validado com `helm lint --strict` e `helm template` (`alpine/helm:3.14.4`), incluindo teste manual com uma terceira stack fictícia; HLM-17 a HLM-21 concluídas — `[Claude Code - 2026-07-14]`
- `charts/tekton-project` — quinto chart da migração (Épico 5, Sprint 6): Namespace `proj-<name>`, Secret `gitlab-basic-auth` (`type: kubernetes.io/basic-auth`, annotation `tekton.dev/git-0`) e ServiceAccount `pipeline-runner`, parametrizados em `project.name`/`project.stack`/`project.gitlabPAT`/`project.gitlabURL`/`project.labels`, com `required` bloqueando release sem `project.name`/`gitlabPAT`. Reproduz o comportamento de `scripts/onboarding/new-app.sh` e `yaml/projects/pipeline-runner-sa.yaml.tpl`. Validado com `helm lint --strict` e `helm template` de duas releases com nomes diferentes sem conflito de namespace (HLM-23); HLM-22 e HLM-23 concluídas — `[Claude Code - 2026-07-23]`
- `helmfile.yaml.gotmpl` + `values-lab.yaml` — Helmfile orquestrando uma release de `charts/tekton-project` por projeto (`proj-backend-payments`, `proj-frontend-portal` de exemplo), PAT de cada projeto resolvido via `requiredEnv` (nunca commitado, ver ADR-03) e valores comuns (`gitlabUser`/`gitlabURL`) centralizados em `values-lab.yaml`; `.gitignore` atualizado com `values-local.yaml`/`values-secret*.yaml`. Extensão `.gotmpl` necessária: Helmfile v1 só faz templating Go em arquivos `.yaml.gotmpl` — testado com `ghcr.io/helmfile/helmfile:v1.7.1` (`helmfile lint`/`template`, com e sem env vars, confirmando que `requiredEnv` bloqueia release sem PAT); HLM-24 concluída — `[Claude Code - 2026-07-23]`
- `docs/03-onboarding-app-java.md` §3 — documentado o fluxo de onboarding via Helmfile como opção recomendada, mantendo script e passo a passo manual como alternativas; HLM-26 concluída — `[Claude Code - 2026-07-23]`
- `docs/04-ci-operacional.md` §6a — playbook de rollout de Task Bundle via Helm (`charts/tekton-bundles` + `charts/tekton-platform`: nova tag, canário via entrada temporária em `platform.stacks`, migração do Pipeline oficial e rollback com `helm upgrade`/`helm rollback`), preservando a disciplina do ADR-003; playbook manual original preservado como §6b; HLM-16 concluída (adiada do Sprint 4) — `[Claude Code - 2026-07-23]`
- `charts/tekton-platform` — Service NodePort `tekton-dashboard-np` (namespace `tekton-pipelines`, réplica de `docs/01-infraestrutura-base.md` §12 Opção 2), parametrizado em `dashboard.enabled`/`namespace`/`port`/`nodePort` (default `32097`). HLM-27 tinha ficado de fora do Sprint 3 original — feita aqui como pré-requisito de HLM-28. Chart version 0.2.0 → 0.3.0; HLM-27 e HLM-28 concluídas — `[Claude Code - 2026-07-23]`
- `charts/tekton-registry` — `securityContext` nos pods (`runAsNonRoot`, `runAsUser`, `fsGroup`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, capabilities `drop: [ALL]`), parametrizado em `values.yaml`; não validado contra cluster real (só `helm lint`/`helm template` — sem cluster disponível nesta migração). Chart version 0.1.0 → 0.2.0; HLM-30 concluída — `[Claude Code - 2026-07-23]`
- `resources` (requests/limits) parametrizados em todos os pods gerenciados pelos charts: `charts/tekton-registry` (Deployment), `charts/tekton-bundles` (Job de push), `charts/tekton-platform` (Job de feature flags e Pod do `helm test`); `charts/tekton-project` não cria pods, fora do escopo. HLM-31 concluída — `[Claude Code - 2026-07-23]`
- `helmfile.yaml.gotmpl` — bloco `environments:` (`default`/`lab`/`prod`), com `default` e `lab` apontando para `values-lab.yaml` (preserva o comportamento de `helmfile apply` sem `-e`) e `prod` para o novo `values-prod.yaml` — scaffold com placeholders, já que este lab só tem um cluster real hoje (`lab`). Releases passaram a consumir `project.gitlabUser`/`project.gitlabURL` do ambiente selecionado em vez de um arquivo fixo por release. Validado com `helmfile lint`/`template` nos três ambientes (`default`, `-e lab`, `-e prod`) via `ghcr.io/helmfile/helmfile:v1.7.1`; HLM-25 concluída — `[Claude Code - 2026-07-23]`
- `docs/decisions/ADR-006-avaliacao-sealed-secrets.md` — avaliação de Sealed Secrets para os PATs do GitLab (HLM-32): decisão de não adotar agora (uso individual, GitLab local isolado sem exposição externa), condições de revisão documentadas (mais operadores, PATs com escopo maior, ou saída do estágio de lab pessoal); HLM-32 concluída — `[Claude Code - 2026-07-23]`
- `.gitlab-ci.yml` — CI dos próprios charts Helm (Épico 8, Sprint 8, meta): jobs `helm lint --strict`/`helm template` nos 4 charts em todo MR e push no branch default (HLM-33, validado localmente reproduzindo os comandos via `alpine/helm:3.14.4`), e jobs `helm upgrade --install --dry-run` como `when: manual` com guarda explícita (falha com mensagem clara se `KUBECONFIG_TEST_CLUSTER` não estiver configurada, em vez de fingir sucesso — HLM-34). `yaml/tasks/helm-chart-publish.yaml` + `yaml/ci/pipelines/publish-helm-charts-pipeline.yaml` — Pipeline Tekton meta que empacota e publica os 4 charts como artefatos OCI no registry interno via `helm package`/`helm push --plain-http` (HLM-35), com playbook de disparo manual em `docs/04-ci-operacional.md` §11. `docs/decisions/ADR-007-limitacoes-cicd-charts.md` documenta as limitações conhecidas: repo vive no GitHub (não GitLab) e a rede do lab (`192.168.56.0/24`) é inalcançável por runners de CI na nuvem — HLM-34/HLM-35 não puderam ser testados contra infraestrutura real nesta migração, só validação sintática/local. HLM-33, HLM-34 e HLM-35 concluídas — `[Claude Code - 2026-07-23]`

### Alterado
- Comandos operacionais de Helm (`docs/07-bootstrap-helm.md`, `docs/04-ci-operacional.md` §6a, `docs/03-onboarding-app-java.md` §3a) trocados de `docker run ... alpine/helm:3.14.4` para o binário `helm` direto — `helm` passou a estar instalado no host deste lab. Docker continua documentado como alternativa opcional. `.gitlab-ci.yml` e `yaml/tasks/helm-chart-publish.yaml` mantidos com a imagem `alpine/helm:3.14.4` (rodam em CI/cluster, não no host) — `[Claude Code - 2026-07-24]`
- IP do host do GitLab (`192.168.56.1` → `192.168.0.13`) em toda a documentação, `values-lab.yaml`, `charts/tekton-project/values.yaml` e `scripts/onboarding/new-app.sh`: GitLab agora é alcançado pelas VMs via a interface `wlo1` (LAN) em vez de `virbr1` (bridge das VMs, que continua em `192.168.56.1` só para o tráfego interno do cluster k3s) — diagrama de topologia em `README.md` e a explicação em `docs/01-infraestrutura-base.md` §8.1 atualizados para refletir a nova associação de interface — `[Claude Code - 2026-07-24]`
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
