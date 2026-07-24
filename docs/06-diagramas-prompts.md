# Prompts para gerar diagramas com Gemini/Imagen

Prompts para gerar diagramas técnicos usando **Gemini Advanced** ou qualquer modelo com geração de imagem (Imagen). Todos escritos em inglês para melhor fidelidade na renderização.

---

## Infraestrutura e rede

### Diagrama de topologia de rede

```
Create a clean, professional technical infrastructure diagram showing the network
topology of a local Kubernetes lab:

- A large outer rectangle labeled "Host Notebook (Linux)"
- Inside, three network interfaces listed as small text:
  wlo1 (192.168.0.13), virbr0 (192.168.121.1), virbr1 (192.168.56.1 - highlighted)
- Inside the host, a smaller rectangle labeled "GitLab CE (Docker Compose,
  network_mode: host, port 8929)"
- Below GitLab, a large rectangle labeled "k3s Cluster (VMs in libvirt network
  192.168.56.0/24)" containing three server icons labeled:
  "k3s-server (192.168.56.110)", "k3s-agent-1", "k3s-agent-2"
- On the right side of the cluster rectangle, three service badges:
  "Registry NodePort 32000", "EventListener NodePort 32080",
  "Dashboard NodePort 32097"
- An arrow labeled "webhook HTTP POST" from GitLab to EventListener

Style: modern flat design, blue and gray palette, isometric or 2D flat,
technical documentation aesthetic, minimal shadows, clear labels in English,
white background.
```

### Diagrama de componentes Tekton no cluster

```
Create a Kubernetes cluster architecture diagram showing all Tekton components
running in a k3s cluster:

- Outer rectangle "k3s Cluster" containing multiple namespaces as inner boxes:

  Namespace "tekton-pipelines":
    - Tekton Pipelines Controller pod
    - Tekton Pipelines Webhook pod
    - Tekton Triggers Controller pod
    - Tekton Triggers Webhook pod
    - Tekton Core Interceptors pod
    - Tekton Dashboard pod

  Namespace "tekton-pipelines-resolvers":
    - Bundles Resolver pod
    - Git Resolver pod

  Namespace "registry":
    - Docker Registry v2 pod + PVC 20Gi

  Namespace "ci":
    - EventListener pod (gitlab-listener)
    - Pipeline (java-app-pipeline, node-app-pipeline)
    - Trigger, TriggerTemplate, TriggerBinding resources
    - Secret gitlab-webhook-secret
    - Multiple PipelineRun pods

- Arrows connecting components: EventListener → Triggers Controller →
  PipelineRun; Bundles Resolver → Registry

Style: Kubernetes-themed diagram, blue and white palette, containers/pods
as small boxes, namespaces as distinct-colored regions, English labels,
professional cloud-native documentation aesthetic, white background.
```

---

## Fluxos de instalação e execução

### Fluxograma de instalação (fases 1 a 9)

```
Create a vertical flowchart showing 9 sequential installation phases of a
Tekton CI/CD pipeline setup:

Phase 1: Install Tekton (Pipelines + Triggers + Interceptors + Dashboard)
Phase 2: Deploy internal Docker Registry (NodePort 32000) and configure
  registries.yaml on 3 k3s nodes
Phase 3: Create Task Bundles (git-clone, maven-build, kaniko-build-push)
  and push to registry
Phase 4: Define Pipeline that references bundles via resolver
Phase 5: Deploy GitLab CE via Docker Compose with network_mode: host
Phase 6: Create Java app repository (pom.xml, App.java, Dockerfile)
Phase 7: Set up Triggers (RBAC, Secret, TriggerTemplate, EventListener,
  Webhook in GitLab)
Phase 8: Configure Git authentication (PAT + basic-auth secret)
Phase 9: Access Tekton Dashboard for observability

Style: vertical flow, rounded rectangles connected by downward arrows,
each phase numbered and color-coded by category (blue=install, green=config,
orange=integration, purple=observability). Professional technical documentation
style, English labels, white background, clean typography.
```

### Fluxo do webhook até a imagem publicada

```
Create a horizontal end-to-end sequence diagram showing a CI/CD workflow:

Actors from left to right:
1. Developer (person icon) with label "git push"
2. GitLab CE server icon (192.168.0.13:8929) — detects push, creates
   "Push Hook"
3. Tekton EventListener (192.168.56.110:32080) — validates X-Gitlab-Token,
   runs interceptor, extracts params via TriggerBinding, renders TriggerTemplate
4. Kubernetes PipelineRun resource created in namespace "ci"
5. Bundles Resolver — pulls Tasks from internal registry
6. Three sequential Task boxes:
   "git-clone" → "maven-build (mvn package)" → "kaniko-build-push"
7. Internal Docker Registry showing final image "apps/demo-app:<sha>"

Between the tasks, show a shared PVC workspace icon.
Arrows between components should have short labels (POST, creates, pulls,
runs, pushes).

Style: modern isometric diagram, blue/purple/green palette, professional
DevOps documentation aesthetic, English labels, white background.
```

---

## Arquitetura multi-tenant

### Arquitetura multi-tenant final

```
Create a professional Kubernetes multi-tenant CI/CD architecture diagram:

Central-top: large rectangle "namespace: ci (Platform)" containing:
- "Pipeline: java-app-pipeline"
- "Pipeline: node-app-pipeline"
- "EventListener: gitlab-listener (NodePort 32080)"
- "Trigger with gitlab + cel interceptors"
- "TriggerBinding + TriggerTemplate (app-template)"
- "ServiceAccount: tekton-triggers-sa"
- "Secret: gitlab-webhook-secret"

Below, three tenant namespaces side by side:
- "proj-backend-java-app" (Java)
- "proj-frontend-angular" (Node)
- "proj-backend-payments" (Java)

Each tenant contains:
- "ServiceAccount: pipeline-runner"
- "Secret: gitlab-basic-auth"
- "PipelineRuns"

Arrows:
- Downward arrow from ci to each tenant labeled
  "CEL routes based on repo prefix (frontend-*, backend-*)"
- Arrow from each PipelineRun back to ci labeled
  "resolver: cluster (fetches Pipeline)"
- Small box on the right: "Registry (Task Bundles + Images)"
  with arrow from Pipelines labeled "resolver: bundles"

Style: clean cloud-native architecture diagram, blue and green palette,
Kubernetes-themed, English labels, white background, professional.
```

### Sequência do roteamento CEL

```
Create a horizontal sequence diagram showing CEL-based routing decisions:

Step 1: GitLab webhook arrives with payload:
  {"project": {"name": "frontend-angular"}, "checkout_sha": "abc..."}

Step 2: gitlab interceptor validates X-Gitlab-Token → success

Step 3: cel interceptor filter:
  body.project.name.startsWith('frontend-') ||
  body.project.name.startsWith('backend-')
  → passes filter

Step 4: cel overlays compute:
  target-namespace = "proj-" + "frontend-angular" = "proj-frontend-angular"
  pipeline-name = "node-app-pipeline" (starts with frontend-)
  repo-name = "frontend-angular"

Step 5: TriggerBinding + TriggerTemplate render PipelineRun with:
  namespace: proj-frontend-angular
  pipelineRef.name: node-app-pipeline
  pipelineRef.resolver: cluster
  serviceAccountName: pipeline-runner

Step 6: PipelineRun created and starts running

Highlight the decision points with question marks and arrows.
Style: modern sequence diagram, purple and orange palette,
English labels, white background, professional DevOps documentation.
```

### Escalabilidade — crescimento multi-projeto

```
Create a scalability diagram showing how the multi-tenant Tekton platform
grows with new projects:

Left: single "Platform namespace (ci)" with icons for EventListener,
Pipeline definitions, RBAC

Right side: 5 tenant namespaces stacked vertically, each with same
internal structure (SA, Secret, PipelineRuns):
- proj-backend-payments
- proj-frontend-portal
- proj-python-api
- proj-backend-orders
- proj-frontend-admin

Between the platform and tenants, a single CEL routing arrow labeled
"CEL: 'proj-' + body.project.name"

Emphasize that adding a new project only requires:
1. Create namespace
2. Create SA + Secret
3. Register webhook

No changes needed to the platform namespace.

Style: cloud-native scalability diagram, blue/purple gradient,
minimal and professional, English labels, white background,
suitable for architecture presentations.
```

---

## RBAC e segurança

### RBAC do EventListener

```
Create a hierarchical RBAC diagram for a Kubernetes Tekton Triggers
EventListener showing the DOUBLE binding requirement:

- Top: single ServiceAccount box labeled "tekton-triggers-sa (namespace: ci)"
- Two branches going down:
  Left branch: RoleBinding (namespaced) → ClusterRole
    "tekton-triggers-eventlistener-roles"
    with permissions listed: Triggers, TriggerBindings, TriggerTemplates,
    EventListeners, PipelineRuns
  Right branch: ClusterRoleBinding (cluster-scoped) → ClusterRole
    "tekton-triggers-eventlistener-clusterroles"
    with permissions listed: ClusterInterceptor, ClusterTriggerBinding
- Add a warning label on the right branch:
  "REQUIRED — without this, EventListener pod crashes in CrashLoopBackOff"

Style: clean hierarchical diagram, boxes and arrows, warning symbol on
the critical branch (yellow/red), professional technical documentation,
English labels, white background.
```

### Cadeia de dependências do namespace ci

```
Create a dependency graph diagram showing what breaks if platform components
of the ci namespace are removed or misconfigured:

Central node: "Webhook received"

Descending tree structure with color-coded impact:

Green nodes (no impact if isolated):
- Individual Pipeline references

Yellow nodes (partial impact):
- Trigger interceptors (gitlab, cel) — "one stack breaks"

Orange nodes (major impact):
- TriggerTemplate app-template — "all new runs break"
- TriggerBinding — "all new runs break"
- gitlab-webhook-secret — "all webhooks silently rejected"

Red nodes (total platform outage):
- ServiceAccount tekton-triggers-sa — "EL crashes"
- ClusterRoleBinding tekton-triggers-sa-cluster — "EL crashes"
- ClusterRoleBinding create-pipelinerun — "runs never created"
- EventListener gitlab-listener — "no webhook received"

Below each node, a small caption with the recovery action.

Style: dependency graph with color-coded severity, incident response
aesthetic, English labels, white background, professional operational
documentation.
```

---

## Playbooks operacionais

### Playbook — adicionar nova app (infográfico)

```
Create a 6-step vertical checklist-style flowchart for onboarding a new
application to the Tekton multi-tenant platform:

Step 1: "Name your repo with prefix (backend-* or frontend-*)"
        Icon: Git branch
Step 2: "Create GitLab project (Internal visibility)"
        Icon: GitLab logo
Step 3: "Generate a dedicated PAT (read_repository scope)"
        Icon: key
Step 4: "Provision namespace: create ns, secret, ServiceAccount"
        Icon: Kubernetes namespace
        Sub-items:
          - kubectl create ns proj-<repo>
          - kubectl create secret basic-auth + annotate
          - kubectl apply -f serviceaccount.yaml
Step 5: "Configure GitLab webhook to EventListener
         (URL: http://192.168.56.110:32080)"
        Icon: webhook / connection
Step 6: "Push code with Dockerfile at repo root"
        Icon: rocket

End with a green checkmark: "Pipeline runs automatically on every push"

Style: modern checklist infographic, green and blue palette,
clean icons, English labels, white background,
suitable for onboarding documentation.
```

### Ciclo de vida de uma mudança no ci

```
Create a change management workflow diagram for updating platform
components in the ci namespace:

Horizontal swimlanes for actors:
Lane 1: "Platform Engineer"
Lane 2: "Task Bundle Registry"
Lane 3: "ci namespace"
Lane 4: "proj-* namespaces (existing apps)"

Steps flowing left to right:
1. "Edit Task YAML locally" (Lane 1)
2. "tkn bundle push v2" (Lane 1 → Lane 2)
3. "Create canary Pipeline v2" (Lane 3)
4. "Manual test run in a proj-*" (Lane 4)
5. "Validate output image" (Lane 1)
6. "Edit official Pipeline: bump to v2" (Lane 3)
7. "Delete canary Pipeline" (Lane 3)
8. "Rollback path: revert to :v1" (Lane 3, dashed line back)

Style: swimlane workflow diagram, orange-blue palette, arrows between
lanes, English labels, white background, suitable for runbook
documentation.
```

---

## Apresentação executiva

### Diagrama simplificado (alta visibilidade)

```
Create a simple, elegant high-level architecture diagram for a technical
presentation showing an internal CI/CD platform:

Left side: "Developer" icon with arrow pointing right, labeled "git push"

Center: three stacked layers:
  Top: "GitLab CE" (source control)
  Middle: "Tekton on Kubernetes" (CI/CD orchestration)
  Bottom: "Internal Registry" (artifact storage)

Right side: arrow going out labeled "Container image ready for deployment"

Add a small side panel labeled "Reusable Task Bundles" pointing into the
Tekton layer.

Style: minimalist, corporate presentation aesthetic, gradient background,
smooth rounded boxes, subtle icons, professional font, English labels,
suitable for a slide deck.
```
