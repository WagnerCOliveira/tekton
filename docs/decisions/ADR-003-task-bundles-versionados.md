# ADR-003: Task Bundles versionados imutáveis

## Status
Aceito

## Data
2026-07-05 (aproximado — presente desde o commit inicial da infraestrutura base)

## Contexto
As Tasks (`git-clone`, `maven-build`, `node-build`, `kaniko-build-push`) são compartilhadas por todos os Pipelines e todos os projetos. Alterar uma Task diretamente no cluster (`kubectl apply` sobre a mesma definição) afeta **todos** os `PipelineRun` — em execução e futuros — sem possibilidade de rollback rápido, e o Tekton faz cache dos bundles por digest, então o comportamento de "quem pegou a versão nova vs. a antiga" fica imprevisível durante a sobrescrita.

## Decisão
Publicar Tasks como **Task Bundles** (artefatos OCI, mesma tecnologia de imagem Docker) no registry interno, com **tags imutáveis versionadas** (`v1`, `v2`, ...). Nunca sobrescrever uma tag em uso — toda mudança de Task publica uma tag nova, e a migração dos Pipelines para a nova versão é um passo consciente e testável (playbook "Atualizar uma Task existente" em `docs/04-ci-operacional.md` §6, com etapa de canary).

## Consequências

### Positivas
- Versionamento imutável via tags e digests — auditoria clara de qual versão cada Pipeline usa
- Reuso entre múltiplos Pipelines/projetos sem sincronizar CRDs manualmente
- Rollback trivial: trocar a referência de `:v2` para `:v1` no Pipeline e reaplicar

### Negativas
- Requer disciplina operacional — nada no cluster impede tecnicamente sobrescrever uma tag existente, é uma regra de processo, não uma trava técnica
- Mais um artefato para gerenciar (o registry precisa ter storage e ser confiável)

### Neutras (trade-offs)
- Testar uma nova versão de Task exige criar um Pipeline "canary" temporário (`java-app-pipeline-v2`) em vez de simplesmente editar e reaplicar — mais seguro, um passo a mais

## Alternativas consideradas
- **Tag mutável `latest`**: mais simples de operar no dia a dia, mas reintroduz exatamente o problema que motivou esta decisão (mudança silenciosa afetando todos os runs)
- **Git resolver** (referenciar a Task direto de um repo Git em vez de bundle OCI): elimina o passo de publish, mas acopla a execução do Pipeline à disponibilidade do Git remoto e perde a garantia de imutabilidade por digest que o registry OCI dá

## Referências
- [`docs/04-ci-operacional.md`](../04-ci-operacional.md) §6 — playbook "Atualizar uma Task existente"
- [Tekton Bundles Resolver](https://tekton.dev/docs/pipelines/bundle-resolver/)
