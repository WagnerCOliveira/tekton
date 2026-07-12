# Relatório de Consolidação — 2026-07-12

## Executado por
Claude Code, a partir de `prompt-consolidacao-tekton.md`, com duas decisões de escopo confirmadas pelo usuário antes da execução:
1. `README.md` continua sendo o hub central (não `tekton-multitenant.md`) — convenção GitHub/GitLab de renderizar o README na raiz.
2. Reestruturação física completa (`docs/`, `scripts/`, `yaml/`), como pedido no prompt original.

## Resumo

- **11** arquivos `.md` auditados + **1** `.sh` pré-existente
- **7** documentos movidos/renomeados para `docs/01-06-*.md` + `docs/roadmap-helm.md`
- **2** documentos órfãos (já marcados "supersedido" desde 2026-07-06) movidos para `_workspace/pending-review/`
- **12** scripts criados/reorganizados em `scripts/{setup,ops,onboarding}/` (11 novos + 1 relocado)
- **13** manifestos YAML canônicos extraídos para `yaml/{ci,projects,tasks}/`
- **5** ADRs criados em `docs/decisions/` + `_template.md` + `README.md` (índice)
- **6** entradas de versão reconstruídas em `CHANGELOG.md` (1.0.0 → Não lançado)
- **0** arquivos apagados — tudo movido ou preservado

## Mudanças estruturais

| De | Para |
|---|---|
| `tekton-lab-setup.md` | `docs/01-infraestrutura-base.md` (+ removida cauda duplicada de 432 linhas — prompts Gemini e troubleshooting legados, já presentes na íntegra em `docs/06` e `docs/05`) |
| `tekton-multitenant.md` | `docs/02-arquitetura-multitenant.md` |
| `tekton-template-novo-projeto-java.md` | `docs/03-onboarding-app-java.md` |
| `tekton-ci-playbook.md` | `docs/04-ci-operacional.md` (+ removida cauda duplicada de 115 linhas — prompts Gemini legados) |
| `troubleshooting.md` | `docs/05-troubleshooting.md` |
| `gemini-prompts.md` | `docs/06-diagramas-prompts.md` |
| `helm-backlog.md` | `docs/roadmap-helm.md` |
| `tekton-passo1-multitenant.md` | `_workspace/pending-review/tekton-passo1-multitenant.md` |
| `tekton-multitenant-e-playbook.md` | `_workspace/pending-review/tekton-multitenant-e-playbook.md` |
| `fix-pipelinerun-namespace.sh` (raiz) | `scripts/ops/fix-pipelinerun-namespace.sh` |

Todos os links internos (`[texto](arquivo.md)`), âncoras de seção e caminhos de imagem (`imagens/*.png` → `../imagens/*.png` a partir de `docs/`) foram reescritos e verificados automaticamente (script Python ad-hoc que resolve cada link relativo e confirma que o arquivo existe — nenhum link quebrado encontrado, exceto a referência a este próprio relatório antes de ele existir).

Novos artefatos criados:
- `CHANGELOG.md` — formato Keep a Changelog + SemVer, reconstruído a partir de `git log` (4 commits reais + trabalho desta sessão)
- `docs/decisions/ADR-001` a `ADR-005` + `_template.md` + `README.md` (índice + regras de quando criar um ADR)
- `README.md` §"O que mudou recente" — tabela das 3 últimas mudanças arquitetônicas com link pro ADR correspondente
- `scripts/setup/01-05` — instalação do Tekton, registry, `registries.yaml` por nó, bootstrap do `ci`, publicação de bundles
- `scripts/ops/*` — diagnóstico do EL, mostrar token, listar runs, reiniciar EL, rotacionar token
- `scripts/onboarding/new-app.sh` — onboarding parametrizado (`backend|frontend` + nome)
- `yaml/ci/{rbac,registry}.yaml`, `yaml/ci/pipelines/*.yaml`, `yaml/ci/triggers/*.yaml`, `yaml/tasks/*.yaml`, `yaml/projects/pipeline-runner-sa.yaml.tpl` — fonte de verdade que os scripts aplicam; os `.md` pedagógicos (`docs/02`, `docs/04`) agora referenciam esses arquivos com callouts `📌`/`🔧` em vez de só repetir o heredoc

## Divergências resolvidas

1. **Dois documentos órfãos supersedidos** (`tekton-passo1-multitenant.md`, `tekton-multitenant-e-playbook.md`) — já vinham marcados "ARQUIVO SUPERSEDIDO... pode ser removido" desde o commit `d8fe0cc` (2026-07-06), mas nunca tinham sido de fato removidos ou arquivados. Movidos para `_workspace/pending-review/` — o usuário pode apagá-los com segurança quando revisar.
2. **Conteúdo legado duplicado** dentro de `tekton-lab-setup.md` (prompts Gemini + troubleshooting, ~550 linhas) — confirmado idêntico ao conteúdo canônico em `gemini-prompts.md`/`troubleshooting.md` e removido da cópia legada.
3. **Comandos/YAML canônicos duplicados** em até 3 arquivos diferentes (RBAC do EL, TriggerBinding/Template/Trigger, Pipelines por stack) — extraídos para `yaml/ci/` e `scripts/setup/`; os playbooks operacionais (`docs/04`) agora apontam pros scripts, o doc de arquitetura (`docs/02`) manteve os blocos inline (valor pedagógico) com nota apontando pro arquivo canônico.
4. **`fix-pipelinerun-namespace.sh` referenciado por caminho relativo errado** após a reorganização — corrigido em `docs/05-troubleshooting.md` §7.5 para `../scripts/ops/fix-pipelinerun-namespace.sh`.

## Divergências NÃO resolvidas (precisam revisão humana)

Nenhuma ambiguidade bloqueante restou sem resposta — as duas decisões de escopo genuinamente ambíguas (identidade do hub, profundidade do reorg) foram esclarecidas com o usuário antes da execução (ver topo deste relatório). `_workspace/QUESTIONS.md` não foi criado porque não sobrou nenhuma pergunta pendente.

Um ponto que vale acompanhar, não bloqueante:
- **Validação `kubectl apply --dry-run=client` não pôde ser executada** — este ambiente não tem `kubectl` (não é a máquina do cluster k3s do laboratório). A validação aplicada em `yaml/` foi só de sintaxe YAML (`python3 -c "import yaml"`), que confirma parse válido mas não valida contra o schema real do Kubernetes/Tekton (CRDs). Recomendação: rodar `kubectl apply --dry-run=client -f yaml/...` a partir da máquina com acesso ao cluster antes de considerar os manifestos 100% validados — ou usar `scripts/setup/04-bootstrap-ci.sh`, que já é idempotente e serve como validação de fato (aplica de verdade).

## Sugestões para próximas iterações

1. Depois de revisar `_workspace/`, decidir se apaga `_workspace/pending-review/*.md` (já eram considerados removíveis desde 2026-07-06) e o `AUDIT-*.md` (arquivo temporário desta sessão).
2. Rodar `kubectl apply --dry-run=client` contra os manifestos em `yaml/` a partir de uma máquina com acesso ao cluster, para fechar a lacuna de validação mencionada acima.
3. Testar `scripts/onboarding/new-app.sh` uma vez em ambiente real — ele depende de `envsubst` (pacote `gettext-base` em Debian/Ubuntu), que não foi confirmado como instalado nos nós do laboratório.
4. Considerar mover o próprio `prompt-consolidacao-tekton.md` para `_workspace/` ou para um `docs/meta/` se ele não precisar continuar na raiz do repo depois desta execução — foi deixado no lugar por não estar listado nos "Entregáveis finais" do prompt.
5. O `helm-backlog.md` (agora `docs/roadmap-helm.md`) tem seus próprios "ADR-01 a ADR-05" internos, propostos mas não aceitos — se algum for aceito e implementado futuramente, criar o ADR correspondente em `docs/decisions/` (nota já deixada em `docs/decisions/README.md`).

## Arquivos apagados

Nenhum. Todas as remoções de conteúdo foram, na verdade, movimentações:
- Os dois `.md` órfãos foram para `_workspace/pending-review/` (não apagados; git preserva o histórico via `git mv`, então `git log --follow` continua funcionando neles).
- As caudas duplicadas (prompts Gemini + troubleshooting legados dentro de `tekton-lab-setup.md`/`tekton-ci-playbook.md`) foram removidas dos arquivos que as continham **apenas porque já existiam, palavra por palavra, nos arquivos canônicos correspondentes** (`gemini-prompts.md`→`docs/06`, `troubleshooting.md`→`docs/05`) — nenhuma informação foi perdida, e o conteúdo original continua recuperável no histórico do git (`git show d8fe0cc:tekton-lab-setup.md`, por exemplo).
