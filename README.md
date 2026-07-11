# Plataforma CI/CD com Tekton — Laboratório k3s

Plataforma de CI/CD **multi-tenant** construída com Tekton em cluster k3s local. Integra GitLab Community Edition via webhooks, um registry Docker interno e pipelines versionados como Task Bundles OCI.

---

## Arquitetura

![Diagrama de topologia de rede](imagens/fluxo-do-webhook-ate-a-imagem-publicada.png)

---

## Mapa da documentação

| Arquivo | O que cobre | Quando ler |
|---|---|---|
| [tekton-lab-setup.md](tekton-lab-setup.md) | Infra base: k3s, Tekton, Registry, Task Bundles, GitLab, primeira pipeline | Montando do zero |
| [tekton-multitenant.md](tekton-multitenant.md) | Arquitetura multi-tenant: decisão, implementação, multi-stack, onboarding | Evoluindo para multi-tenant |
| [tekton-template-novo-projeto-java.md](tekton-template-novo-projeto-java.md) | Template copia-e-cola: criar namespace + onboarding de uma nova app Java | Adicionando uma app Java nova |
| [tekton-ci-playbook.md](tekton-ci-playbook.md) | Operação do namespace `ci`: inventário, playbooks, diagnóstico | Operando a plataforma |
| [troubleshooting.md](troubleshooting.md) | Todos os problemas encontrados, organizados por categoria | Investigando um problema |
| [gemini-prompts.md](gemini-prompts.md) | Prompts para gerar diagramas com Gemini/Imagen | Gerando diagramas |
| [helm-backlog.md](helm-backlog.md) | Backlog completo da migração para Helm (38 histórias, 8 sprints) | Planejando a migração Helm |

### Ordem sugerida de leitura

```
1. tekton-lab-setup.md     ← monta a infra e valida um ciclo completo
2. tekton-multitenant.md   ← evolui para multi-tenant e onboarda apps
3. tekton-ci-playbook.md   ← referência operacional da plataforma
4. troubleshooting.md      ← quando algo não funciona
```

---

## Componentes da plataforma

| Componente | Namespace | Acesso externo | Função |
|---|---|---|---|
| Tekton Pipelines | `tekton-pipelines` | — | Executa Tasks e Pipelines |
| Tekton Triggers | `tekton-pipelines` | — | Recebe eventos HTTP e cria PipelineRuns |
| Tekton Dashboard | `tekton-pipelines` | NodePort **32097** | UI de observabilidade |
| Bundles Resolver | `tekton-pipelines-resolvers` | — | Puxa Task Bundles do registry OCI |
| Docker Registry v2 | `registry` | NodePort **32000** | Armazena bundles e imagens finais |
| EventListener | `ci` | NodePort **32080** | Ponto de entrada dos webhooks |
| GitLab CE | Host (Docker Compose) | **:8929** | SCM e emissor de webhooks |

---

## Topologia de rede

```
Host Notebook
├─ wlo1        192.168.0.13    (Wi-Fi)
├─ virbr0      192.168.121.1   (libvirt default)
└─ virbr1      192.168.56.1    (rede das VMs k3s)
    │
    ├─ GitLab CE (Docker, network_mode: host) → :8929
    └─ Cluster k3s (192.168.56.0/24)
         ├─ k3s-server   192.168.56.110
         ├─ k3s-agent-1
         └─ k3s-agent-2
               ├─ Registry   → NodePort 32000
               ├─ EL Webhook → NodePort 32080
               └─ Dashboard  → NodePort 32097
```

---

## Convenções de nomeação

| Elemento | Padrão | Exemplo |
|---|---|---|
| Repo GitLab — Java/Maven | `backend-<nome>` | `backend-payments` |
| Repo GitLab — Node/Angular | `frontend-<nome>` | `frontend-portal` |
| Namespace de projeto | `proj-<nome-do-repo>` | `proj-backend-payments` |
| ServiceAccount de execução | `pipeline-runner` (fixo por namespace) | — |
| Secret de auth Git | `gitlab-basic-auth` (fixo por namespace) | — |
| Task Bundle | `tekton/<task>:v<N>` | `tekton/git-clone:v1` |
| Imagem publicada | `apps/<repo>:<sha>` | `apps/backend-payments:82a57d1` |

**Por que o prefixo no repo:** o interceptor CEL do EventListener lê `body.project.name` e usa o prefixo para decidir qual Pipeline aplicar. Sem prefixo, o evento é descartado silenciosamente.

---

## Task Bundles disponíveis

```bash
# Verificar catálogo
curl -s http://192.168.56.110:32000/v2/_catalog

# Listar tags de um bundle
curl -s http://192.168.56.110:32000/v2/tekton/git-clone/tags/list
```

| Bundle | Imagem base | Função |
|---|---|---|
| `tekton/git-clone:v1` | `alpine/git:2.43.0` | Clone + checkout |
| `tekton/maven-build:v1` | `maven:3.9-eclipse-temurin-17` | `mvn clean package` |
| `tekton/node-build:v1` | `node:20-alpine` | `npm install` + `npm run build` |
| `tekton/kaniko-build-push:v1` | `gcr.io/kaniko-project/executor:v1.23.2` | Build + push de imagem |

---

## Checklist rápido — adicionar uma nova app

```
[ ] Criar repo no GitLab com prefixo backend- ou frontend-
[ ] Gerar PAT (scope: read_repository)
[ ] kubectl create ns proj-<repo>
[ ] Criar secret gitlab-basic-auth com o PAT + anotação tekton.dev/git-0
[ ] Criar ServiceAccount pipeline-runner com o secret anexado
[ ] Cadastrar webhook no GitLab → http://192.168.56.110:32080
[ ] Garantir Dockerfile na raiz do repo
[ ] git push → pipeline roda automaticamente
```

Tempo estimado: ~5 minutos por app.

---

## Roadmap

1. **Helm** — migrar toda a configuração para charts Helm (ver [helm-backlog.md](helm-backlog.md))
2. **Testes** — Task `maven-test` antes do build, JaCoCo para coverage
3. **CD com ArgoCD** — repo GitOps + Applications sincronizando manifests
4. **Segurança** — Trivy scan na imagem, Cosign para assinatura
5. **Observabilidade** — Prometheus + Grafana + Loki
6. **Promoção entre ambientes** — dev → staging → prod via MR
