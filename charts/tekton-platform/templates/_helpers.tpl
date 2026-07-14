{{/*
Token do secret do webhook — gera com randAlphaNum 40 se não vier de .Values.webhook.token,
e preserva o valor já existente no cluster em upgrades (evita rotacionar o token à toa).
*/}}
{{- define "tekton-platform.webhookToken" -}}
{{- $existing := lookup "v1" "Secret" .Values.namespace .Values.webhook.secretName -}}
{{- if .Values.webhook.token -}}
{{ .Values.webhook.token | b64enc }}
{{- else if $existing -}}
{{ index $existing.data "secretToken" }}
{{- else -}}
{{ randAlphaNum 40 | b64enc }}
{{- end -}}
{{- end -}}
