# ADR-002: Roteamento por prefixo do repo via interceptor CEL

## Status
Aceito

## Data
2026-07-06 (aproximado)

## Contexto
Com o [Padrão B](ADR-001-padrao-b-multitenant.md) adotado, o `EventListener` único em `ci` precisa decidir, a partir do payload do webhook do GitLab, três coisas por push: em qual namespace criar o `PipelineRun` (`target-namespace`), qual o nome do repo (`repo-name`) e qual Pipeline aplicar (`pipeline-name`) — já que a plataforma passou a suportar múltiplas stacks (Java/Maven e Node/Angular, com Python planejado).

## Decisão
Usar o **prefixo do nome do repositório GitLab** (`backend-*` para Java, `frontend-*` para Node) como sinal de roteamento, calculado pelo interceptor `cel` do Tekton Triggers a partir de `body.project.name`:

```yaml
filter: >-
  body.project.name.startsWith('frontend-') ||
  body.project.name.startsWith('backend-')
overlays:
- key: target-namespace
  expression: "'proj-' + body.project.name"
- key: repo-name
  expression: "body.project.name"
- key: pipeline-name
  expression: |
    body.project.name.startsWith('frontend-') ? 'node-app-pipeline' :
    body.project.name.startsWith('backend-')  ? 'java-app-pipeline' :
    'UNKNOWN'
```

Repos sem prefixo reconhecido são descartados silenciosamente pelo `filter` (nenhum `PipelineRun` é criado).

## Consequências

### Positivas
- Zero configuração adicional por projeto — só a convenção de nome do repo já basta para o roteamento funcionar
- Fácil de estender para novas stacks: um novo `startsWith` no filter e no overlay (ver playbook "Adicionar suporte a uma nova stack" em `docs/04-ci-operacional.md`)

### Negativas
- Convenção de nome é uma **convenção implícita**, não validada pelo GitLab — nada impede alguém de criar um repo sem prefixo e ficar confuso com o silêncio do webhook
- CEL incompleto (faltando `filter` ou o overlay `pipeline-name`) é uma classe inteira de bug já documentada (`troubleshooting.md` §7.1 e §7.5) — regressão observada em produção quando uma correção parcial reintroduziu roteamento hardcoded

### Neutras (trade-offs)
- Prefixo por nome de repo é mais simples que label do GitLab ou grupo dedicado, mas amarra a convenção de nomenclatura à lógica de roteamento — renomear um repo quebra o roteamento

## Alternativas consideradas
- **Label no repo GitLab**: mais explícito, mas exige a API do GitLab para ler labels no interceptor (não suportado nativamente pelo interceptor `gitlab`/`cel` sem uma chamada extra)
- **Grupo do GitLab dedicado por stack**: viável, mas exige reorganizar a estrutura de grupos existente e o payload do webhook não traz o grupo de forma tão direta quanto `project.name`

## Referências
- [`docs/02-arquitetura-multitenant.md`](../02-arquitetura-multitenant.md) §6 — "Como o EventListener roteia o webhook (CEL)"
- [Tekton CEL Interceptor](https://tekton.dev/docs/triggers/cel_expressions/)
