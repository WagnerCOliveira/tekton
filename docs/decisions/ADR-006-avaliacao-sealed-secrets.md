# ADR-006: Não adotar Sealed Secrets no lab (por enquanto)

## Status
Aceito

## Data
2026-07-23

## Contexto
HLM-32 (Épico 7, Sprint 7 de `docs/roadmap-helm.md`) pede uma avaliação formal de [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) para armazenar os PATs do GitLab (`project.gitlabPAT`, usado pelo chart `charts/tekton-project`) de forma segura versionada no Git.

Hoje (ver ADR-03 dentro de `docs/roadmap-helm.md`) o PAT nunca é commitado: é passado via `requiredEnv` no `helmfile.yaml.gotmpl` (Sprint 6, HLM-24), exportado pelo operador antes de rodar `helmfile apply`, ou via `--set` direto no `helm install`. Isso funciona, mas tem uma lacuna real: **o PAT em texto puro passa pela memória do shell e pelo histórico de comandos do operador**, e não há nenhum registro auditável de "quem tinha acesso a qual PAT quando" além do próprio GitLab.

Sealed Secrets resolveria isso: o operador cripta o PAT localmente com a chave pública do controller (`kubeseal`), o `SealedSecret` resultante é seguro para commitar no Git, e só o controller rodando no cluster consegue decriptá-lo — nem quem tem acesso ao repo, nem quem tem `kubectl get secret -o yaml` sem a chave privada do controller.

## Decisão
**Não adotar Sealed Secrets agora.** Manter `requiredEnv`/`--set` (ADR-03) como abordagem do lab. Revisitar esta decisão se qualquer uma destas condições mudar:
- O lab passar a ter mais de uma pessoa operando (hoje é uso individual — não há "quem tinha acesso" a auditar além do próprio operador)
- Os PATs passarem a proteger algo além de `read_repository` em repositórios de um GitLab local isolado (`192.168.56.1:8929`, sem exposição externa)
- O projeto sair do estágio de laboratório pessoal (ver `README.md` para o contexto geral da plataforma)

## Consequências

### Positivas
- Zero infraestrutura nova para manter (sem controller Sealed Secrets rodando, sem chave privada pra fazer backup/rotacionar)
- Onboarding de projeto continua em um único passo (`export PAT_X=... && helmfile apply`), sem a etapa extra de `kubeseal`
- Consistente com a decisão já tomada em ADR-03 — não reabre uma discussão já resolvida sem fato novo

### Negativas
- PAT passa em texto puro pela env var/histórico do shell do operador durante o `helmfile apply` — pior postura de segurança que Sealed Secrets, aceitável só porque o "blast radius" de hoje é um cluster k3s local de um único operador
- Se o lab crescer (mais operadores, PATs com escopo maior), a lacuna documentada acima vira um risco real, não hipotético

### Neutras (trade-offs)
- Nada no repositório impede fisicamente alguém de decidir revisitar isso amanhã — a estrutura via Helm (`charts/tekton-project`) já isola o Secret por release, o que facilitaria a migração para `SealedSecret` no futuro sem redesenhar o chart, só trocando `templates/secret.yaml` por um `SealedSecret` e adicionando o passo `kubeseal` no fluxo do Helmfile

## Alternativas consideradas
- **Sealed Secrets** (opção avaliada nesta ADR): resolve o problema real de PAT em texto puro, mas adiciona um controller pra manter, uma chave privada pra fazer backup (perder a chave = perder todos os SealedSecrets existentes) e um passo manual (`kubeseal`) no onboarding — custo desproporcional ao risco atual de um cluster de uso individual
- **External Secrets Operator**: ainda mais infraestrutura (precisa de um backend externo — Vault, AWS Secrets Manager etc. — que este lab não tem e não pretende ter) — descartado pelo mesmo motivo já registrado em ADR-03
- **Manter como está** (decisão tomada): menor custo operacional, risco proporcional ao contexto de uso atual

## Referências
- ADR-03 (dentro de `docs/roadmap-helm.md`) — decisão original de usar `--set`/`values-local.yaml` para o PAT
- `charts/tekton-project/templates/secret.yaml` — onde um `SealedSecret` substituiria o `Secret` atual, se esta decisão for revertida
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
- [External Secrets Operator](https://external-secrets.io/)
