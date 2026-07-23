{{/*
Namespace do projeto — proj-<project.name>. project.name é obrigatório.
*/}}
{{- define "tekton-project.namespace" -}}
proj-{{ required "project.name é obrigatório (nome completo do repo, ex.: backend-payments)" .Values.project.name }}
{{- end -}}
