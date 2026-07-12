# Prompt: Consolidação e Estratégia de Memória — Plataforma Tekton no k3s

> **Uso:** cole este documento inteiro como prompt para o Claude Code (ou outro agente de codificação) executar em ambiente onde os arquivos `.md`, `.sh` e YAMLs do projeto Tekton estão acessíveis.

---

## Contexto do projeto

Existe uma plataforma de CI/CD baseada em **Tekton em cluster k3s** (1 server + 2 agents), integrada com **GitLab CE** rodando via Docker Compose no host. A plataforma segue o **padrão B multi-tenant**:

- Namespace `ci` concentra Pipelines, EventListener e roteamento (é a **plataforma**)
- Namespaces `proj-<repo>` isolam cada aplicação (é o **tenant**)
- Roteamento por prefixo do repo no GitLab (`backend-*` → Java, `frontend-*` → Node)
- Task Bundles publicados em registry interno OCI
- Autenticação Git via PAT + Secret `basic-auth` anotado com URL

Você (Claude Code) já esteve envolvido no projeto e fez correções em arquivos `.md` e `.sh`. Esta é uma tarefa de **consolidação, reestruturação e institucionalização** da documentação como fonte única de verdade.

---

## O que você vai fazer, resumido

1. **Auditar** todos os `.md` e `.sh` do projeto
2. **Consolidar** com hierarquia clara: `tekton-multitenant.md` como hub central
3. **Registrar** o histórico de mudanças em `CHANGELOG.md`
4. **Instaurar** uma estratégia de memória em dois níveis (ADR + índice rápido)
5. **Validar** que a documentação bate com a realidade dos scripts/YAMLs

---

## FASE 1 — Auditoria completa

### 1.1. Inventariar todos os artefatos

Execute uma varredura e produza um relatório interno (que você vai usar nas fases seguintes):

```bash
# Adapte o path base conforme o projeto
find . -type f \( -name "*.md" -o -name "*.sh" -o -name "*.yaml" -o -name "*.yml" \) \
  -not -path "*/node_modules/*" -not -path "*/.git/*" | sort
```

Para cada arquivo `.md`:
- Título (H1)
- Data de criação e última modificação (se disponível via `git log` ou `stat`)
- Seções principais (H2)
- Referências a outros arquivos `.md`

Para cada arquivo `.sh`:
- Propósito (extraído do cabeçalho ou primeiras linhas)
- Comandos externos que invoca (`kubectl`, `docker`, `tkn`, `curl`)
- Se produz side-effects críticos no cluster (`apply`, `delete`, `create`)

Para cada `.yaml`:
- `kind` e `metadata.name`
- Se é um recurso ativo do cluster ou um exemplo/template

### 1.2. Detectar divergências

Compare os documentos entre si e com os scripts. Sinalize (mas ainda **sem alterar**):

- Comandos duplicados em múltiplos MDs — identifique qual é o "canônico"
- Convenções conflitantes (ex: nome de secret diferente em `.md` vs `.sh`)
- Referências quebradas (link para arquivo que não existe)
- Trechos de código em `.md` que não batem com o `.sh` equivalente
- Sintaxe de RBAC/YAML desatualizada em algum lugar

Produza um relatório interno `AUDIT-<timestamp>.md` em `_workspace/audit/` (crie o diretório se não existir). Este arquivo é **temporário** — não vai pro repo final.

---

## FASE 2 — Reestruturação hierárquica

Meta: `tekton-multitenant.md` deve virar o **hub/índice central** da documentação. Outros MDs viram documentos-satélite referenciados a partir dele.

### 2.1. Estrutura final desejada

```
/
├── tekton-multitenant.md          ← HUB CENTRAL (índice + visão geral)
├── CHANGELOG.md                    ← histórico de mudanças
├── docs/
│   ├── 01-infraestrutura-base.md  ← ex tekton-lab-setup.md
│   ├── 02-onboarding-app.md       ← playbook de nova app
│   ├── 03-ci-operacional.md       ← playbook do ci
│   ├── 04-troubleshooting.md      ← consolidado de todos os problemas
│   └── decisions/
│       ├── ADR-001-padrao-b-multitenant.md
│       ├── ADR-002-roteamento-cel-prefixo.md
│       ├── ADR-003-task-bundles-versionados.md
│       └── ADR-NNN-....md
├── scripts/
│   ├── setup/                     ← scripts de bootstrap
│   ├── ops/                       ← scripts operacionais (diagnóstico, rotação de token)
│   └── onboarding/                ← scripts que assistem no onboarding de nova app
└── yaml/
    ├── ci/                        ← recursos do namespace ci
    ├── projects/                  ← templates de proj-*
    └── tasks/                     ← Tasks fonte dos bundles
```

### 2.2. Regras de reorganização

1. **Mover, não duplicar.** Se conteúdo já existe em um arquivo, remova do outro e crie um link `[texto](path)`.
2. **Não perder informação.** Se você não tem certeza se um trecho é obsoleto, mova para `_workspace/pending-review/` em vez de deletar.
3. **Preservar comandos que funcionaram.** YAMLs e comandos testados são valor — mantenha exatamente como estão, só reorganize onde vivem.
4. **Padronizar callouts.** Use os mesmos marcadores em todo o projeto:
   - `> ✅ Validado` para trechos confirmados em produção
   - `> ⚠️ Atenção` para pegadinhas conhecidas
   - `> 🔧 Playbook` para blocos passo a passo
   - `> 📌 Decisão` para escolhas arquitetônicas com link pro ADR correspondente

### 2.3. Conteúdo do `tekton-multitenant.md` (hub)

Este arquivo deve conter:

**Seção "Sobre esta documentação"** — o que é esse projeto, quando usar cada doc.

**Seção "Mapa da documentação"** — tabela com todos os docs e propósito de cada:

```markdown
| Documento | Quando consultar |
|---|---|
| [Infraestrutura base](docs/01-infraestrutura-base.md) | Bootstrap inicial do cluster |
| [Onboarding de app](docs/02-onboarding-app.md) | Adicionar nova aplicação |
| [Operação do ci](docs/03-ci-operacional.md) | Manter/recuperar a plataforma |
| [Troubleshooting](docs/04-troubleshooting.md) | Algo quebrou |
| [ADRs](docs/decisions/) | Entender por que algo é do jeito que é |
| [CHANGELOG](CHANGELOG.md) | O que mudou recentemente |
```

**Seção "Convenções vigentes"** — a fonte da verdade das nomeações:
- Prefixos de repo (`backend-`, `frontend-`, …)
- Padrão de namespace (`proj-<repo>`)
- Nomes fixos (`pipeline-runner`, `gitlab-basic-auth`, …)
- Portas expostas (32000, 32080, 32097)

**Seção "Arquitetura em uma imagem"** — diagrama ASCII ou referência a imagem gerada.

**Seção "Início rápido"** — top 5 comandos que resolvem 80% das dúvidas:
- Como saber o status geral
- Como adicionar uma app
- Como ver os últimos runs
- Como recuperar o EL
- Como acessar o dashboard

**Seção "Estratégia de evolução"** — link para ADRs e explicação de como decisões novas são registradas.

---

## FASE 3 — CHANGELOG.md

Criar `CHANGELOG.md` na raiz seguindo o padrão [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/), com **Semantic Versioning**.

### 3.1. Estrutura

```markdown
# Changelog

Todas as mudanças notáveis neste projeto serão documentadas aqui.
O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e este projeto adere a [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [Não lançado]
### Adicionado
### Alterado
### Corrigido
### Removido

## [1.2.0] - AAAA-MM-DD
### Adicionado
- Roteamento CEL por prefixo (frontend-*/backend-*)
- Pipeline node-app-pipeline para stack Angular
- Task Bundle node-build:v1

### Alterado
- TriggerTemplate renomeado de java-app-template para app-template (genérico)
- Pipeline java-app-pipeline agora usa cluster resolver quando invocado de proj-*

### Corrigido
- Falha do `npm ci` sem package-lock.json → default trocado para `npm install`
- Interpolação $(comando) no script da Task node-build causando parse error no bundle push

## [1.1.0] - AAAA-MM-DD
### Adicionado
- Padrão B multi-tenant: PipelineRuns em proj-<repo>
- ClusterRole `tekton-triggers-create-pipelinerun`
- Cluster resolver habilitado

## [1.0.0] - AAAA-MM-DD
### Adicionado
- Setup inicial single-tenant no namespace ci
- Task Bundles: git-clone, maven-build, kaniko-build-push
- EventListener + webhook GitLab
```

### 3.2. Como você (Claude Code) preenche o histórico

Reconstrua o histórico a partir de:
- `git log` do repo (se existir)
- Datas de modificação dos arquivos
- Ordem lógica descrita nos MDs existentes
- Suas próprias intervenções recentes — marque explicitamente como `[Claude Code - AAAA-MM-DD]` quando você foi o autor da mudança

Se alguma informação de data estiver ausente, use `AAAA-MM-DD (aproximado)` e explique no rodapé.

### 3.3. Manutenção contínua

Adicione ao final do `CHANGELOG.md`:

```markdown
---

## Como manter este arquivo

- Toda mudança em Pipelines, Tasks ou Triggers no `ci` gera uma entrada
- Onboarding de nova app NÃO gera entrada aqui (é operação corrente)
- Correções críticas de bug em produção geram bump de PATCH (X.Y.Z+1)
- Novos padrões/convenções geram bump de MINOR (X.Y+1.0)
- Mudança que quebra compatibilidade com apps existentes gera bump de MAJOR (X+1.0.0)
```

---

## FASE 4 — Estratégia de memória em dois níveis

O usuário quer **memória completa (ADRs) + índice rápido do recente**. Implemente assim:

### 4.1. Nível "recente" — no hub

No `tekton-multitenant.md`, ao final, criar uma seção:

```markdown
## O que mudou recente

Últimas 3 mudanças significativas. Para histórico completo, ver [CHANGELOG.md](CHANGELOG.md).

| Data | Mudança | Impacto | Link |
|---|---|---|---|
| AAAA-MM-DD | Roteamento CEL por prefixo | Plataforma passou a suportar múltiplas stacks | [ADR-002](docs/decisions/ADR-002-roteamento-cel-prefixo.md) |
| AAAA-MM-DD | Padrão B multi-tenant | Cada projeto tem seu namespace isolado | [ADR-001](docs/decisions/ADR-001-padrao-b-multitenant.md) |
| AAAA-MM-DD | Task Bundles versionados | Rollback ficou trivial | [ADR-003](docs/decisions/ADR-003-task-bundles-versionados.md) |
```

Essa tabela deve ser atualizada a cada mudança arquitetônica (não a cada onboarding).

### 4.2. Nível "profundo" — ADRs (Architecture Decision Records)

Criar `docs/decisions/` com um ADR por decisão importante já tomada. Use o **template Michael Nygard** (adaptado):

```markdown
# ADR-NNN: <Título curto e imperativo>

## Status
<Proposto | Aceito | Depreciado | Substituído por ADR-XXX>

## Data
AAAA-MM-DD

## Contexto
O que estava acontecendo que gerou a necessidade dessa decisão?
Quais eram as opções na mesa?

## Decisão
O que foi decidido, de forma imperativa e curta.

## Consequências
### Positivas
- ...
### Negativas
- ...
### Neutras (trade-offs)
- ...

## Alternativas consideradas
- **Opção X**: por que foi descartada
- **Opção Y**: por que foi descartada

## Referências
- Link para PR/commit que implementou
- Link para documentos técnicos externos
```

### 4.3. ADRs mínimos que você deve criar (a partir do que já sabemos)

Baseado no histórico do projeto, criar pelo menos estes:

1. **ADR-001: Adotar padrão B multi-tenant**
   - Contexto: começamos com tudo em `ci`, sem isolamento
   - Decisão: Pipeline em `ci`, PipelineRuns em `proj-<repo>`
   - Alternativas: padrão A (centralizado), padrão C (só bundles)

2. **ADR-002: Roteamento por prefixo do repo via CEL**
   - Contexto: precisávamos suportar múltiplas stacks
   - Decisão: prefixo (`backend-`/`frontend-`) determina Pipeline
   - Alternativas: label no repo, grupo do GitLab

3. **ADR-003: Task Bundles versionados imutáveis**
   - Contexto: alterar Task no cluster afeta runs em curso
   - Decisão: nova versão = nova tag (`v1`, `v2`), nunca sobrescrever
   - Alternativas: mutable tag `latest`, resolver git

4. **ADR-004: GitLab CE via Docker Compose com network_mode: host**
   - Contexto: container em rede Docker isolada não roteava pra VMs
   - Decisão: `network_mode: host` no compose
   - Alternativas: docker network create com bridge para libvirt

5. **ADR-005: Registry interno HTTP com registries.yaml**
   - Contexto: lab local, sem TLS
   - Decisão: registry inseguro + config nos 3 nós do k3s
   - Alternativas: Harbor com TLS, registry externo autenticado

### 4.4. Como novos ADRs nascem

Adicione em `docs/decisions/README.md`:

```markdown
# Architecture Decision Records

Todo ADR começa com o próximo número sequencial disponível.
Todo ADR nasce em status "Proposto".

## Quando criar um ADR

- Nova convenção que afeta múltiplos projetos
- Mudança de padrão arquitetônico
- Escolha de tecnologia/ferramenta que impacta operação
- Trade-off deliberado em segurança/performance/simplicidade

## Quando NÃO criar

- Escolhas de implementação triviais
- Correções de bug pontuais (esses vão pro CHANGELOG)
- Onboarding de nova aplicação

## Template
Ver `_template.md` neste diretório.
```

Crie também `docs/decisions/_template.md` com o modelo da seção 4.2.

---

## FASE 5 — Consistência entre docs e scripts

Este é o passo mais crítico e onde você (Claude Code) mais agrega valor.

### 5.1. Auditar comandos duplicados

Para cada comando `kubectl`, `docker`, `tkn` que aparece em múltiplos arquivos, decida:

- Se é um **playbook manual** → fica no `.md`
- Se é uma **operação repetível/automável** → migra pra um `.sh` em `scripts/`, e o `.md` referencia com "veja `scripts/xyz.sh`"

Exemplo de refatoração:

**Antes** (repetido em 3 MDs):
```bash
kubectl -n ci get secret gitlab-webhook-secret -o jsonpath='{.data.secretToken}' | base64 -d
```

**Depois:**
```bash
# scripts/ops/show-webhook-token.sh
#!/usr/bin/env bash
set -euo pipefail
kubectl -n ci get secret gitlab-webhook-secret \
  -o jsonpath='{.data.secretToken}' | base64 -d
echo
```

E nos MDs:
```markdown
Para ver o token do webhook:

    ./scripts/ops/show-webhook-token.sh
```

### 5.2. Scripts que devem existir em `scripts/`

Inventário mínimo:

**`scripts/setup/`**
- `01-install-tekton.sh` — instala Pipelines + Triggers + Dashboard
- `02-install-registry.sh` — deploy do registry interno
- `03-configure-k3s-registries.sh` — configura `/etc/rancher/k3s/registries.yaml` no server (com nota sobre agents)
- `04-bootstrap-ci.sh` — cria toda a estrutura do ns `ci`
- `05-publish-task-bundles.sh` — publica os 4 bundles

**`scripts/ops/`**
- `show-webhook-token.sh`
- `restart-el.sh`
- `list-all-runs.sh`
- `rotate-webhook-token.sh`
- `diagnose-el.sh` — coleta logs + describe + eventos do EL

**`scripts/onboarding/`**
- `new-app.sh <backend|frontend> <nome>` — cria ns + secret + SA (o dev ainda cadastra o webhook e faz push manualmente)

Todos os scripts devem:
- Ter shebang `#!/usr/bin/env bash`
- Iniciar com `set -euo pipefail`
- Ter um bloco de comentário no topo explicando propósito e pré-requisitos
- Aceitar `--help` que imprime uso
- Fazer validação de argumentos antes de qualquer efeito

### 5.3. Validar YAMLs

Para cada `.yaml` em `yaml/`:
- Rodar `kubectl apply --dry-run=client -f <file>` (sem aplicar)
- Se falhar, sinalizar no relatório de auditoria
- Se passar, garantir que o `.md` que referencia esse YAML usa o mesmo caminho

---

## FASE 6 — Relatório final

Ao término, produza um `_workspace/CONSOLIDATION-REPORT.md` (temporário, apagado depois de o usuário revisar):

```markdown
# Relatório de Consolidação — <data>

## Executado por
Claude Code

## Resumo
- N arquivos MD auditados
- N arquivos MD reorganizados
- N arquivos SH criados/refatorados
- N ADRs criados
- N entradas adicionadas ao CHANGELOG

## Mudanças estruturais
[Lista das reorganizações feitas]

## Divergências resolvidas
[Lista dos conflitos encontrados e como foram tratados]

## Divergências NÃO resolvidas (precisam revisão humana)
[Lista de itens que colocamos em _workspace/pending-review/]

## Sugestões para próximas iterações
[O que ainda pode melhorar]

## Arquivos apagados
[Lista + justificativa]
```

---

## Regras invioláveis durante toda a execução

1. **Nunca delete conteúdo sem preservar em `_workspace/pending-review/`.** Se você acha que algo é obsoleto, mova, não delete.
2. **Nunca aplique alterações no cluster.** Este é um trabalho de documentação; nada de `kubectl apply -f`.
3. **Sempre teste sintaxe de YAMLs** com `--dry-run=client` antes de considerar válido.
4. **Sempre teste sintaxe de shell** com `bash -n <script>` antes de considerar válido.
5. **Preserve comandos que funcionaram.** Se o usuário testou e disse que funciona, aquele bloco de código é sagrado — só mova de arquivo, não reescreva.
6. **Se algo estiver ambíguo**, pare e produza uma pergunta em `_workspace/QUESTIONS.md` em vez de decidir sozinho.
7. **Datas.** Se você não tem certeza de uma data, use `AAAA-MM-DD (aproximado)` e nunca invente.
8. **Referências cruzadas.** Todo link entre docs deve ser relativo (`../decisions/ADR-001.md`) e testado pra existir.

---

## Ordem de execução recomendada

```
1. FASE 1 (auditoria) → produz relatório interno
2. FASE 3 (CHANGELOG) → começa vazio, vai sendo preenchido nas próximas fases
3. FASE 4 (ADRs)      → cria os ADRs base a partir do que já sabemos
4. FASE 2 (reestruturação) → move arquivos, atualiza links
5. FASE 5 (consistência) → gera .sh, valida YAMLs
6. FASE 6 (relatório) → resume tudo pra revisão humana
```

CHANGELOG e ADRs primeiro porque servem de referência pras outras fases.

---

## Entregáveis finais

Quando terminar, o repositório deve ter:

- ✅ `tekton-multitenant.md` como hub central com mapa de navegação
- ✅ `CHANGELOG.md` na raiz com histórico completo
- ✅ `docs/` com os documentos-satélite renomeados (01-, 02-, 03-, 04-)
- ✅ `docs/decisions/` com 5+ ADRs base e `_template.md`
- ✅ `scripts/setup/`, `scripts/ops/`, `scripts/onboarding/` populados
- ✅ `yaml/` organizado por escopo (ci/, projects/, tasks/)
- ✅ `_workspace/CONSOLIDATION-REPORT.md` para revisão humana
- ✅ `_workspace/pending-review/` (se houver dúvidas)
- ✅ `_workspace/QUESTIONS.md` (se houver ambiguidades)

Diretórios `_workspace/` são temporários; o usuário decide se apaga após revisar.

---

## Checkpoints durante a execução

A cada fase concluída, imprima no console:

```
[FASE N] Concluída — resumo em 3 linhas
```

Se encontrar bloqueio que não consegue resolver sozinho:

```
[BLOQUEIO] Fase N — descrição — precisa decisão humana
```

E siga para próxima fase se possível, ou pare se a bloqueada for pré-requisito.

---

## Início

Comece pela **FASE 1**. Não peça confirmação — o prompt já é sua autorização.
Quando terminar tudo, imprima o `CONSOLIDATION-REPORT.md` na saída padrão além de escrever no disco.
