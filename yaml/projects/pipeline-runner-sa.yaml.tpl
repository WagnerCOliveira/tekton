# Template — ServiceAccount fixa do namespace de projeto (proj-<repo>).
# Aplicado por scripts/onboarding/new-app.sh, que substitui ${NAMESPACE} antes do apply.
# Nomes `pipeline-runner` e `gitlab-basic-auth` são fixos: o TriggerTemplate app-template
# (yaml/ci/triggers/app-template.yaml) referencia esses nomes literalmente.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pipeline-runner
  namespace: ${NAMESPACE}
secrets:
- name: gitlab-basic-auth
