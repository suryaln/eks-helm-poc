{{/* Unified naming: <release>-<chart>, max 63 chars */}}
{{- define "common.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "common.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "common.labels" -}}
{{ include "common.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ default "threetier" .Values.global.appName }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
{{- end -}}

{{/* Names shared across tiers (all derived from the release name) */}}
{{- define "common.serviceAccountName" -}}{{ printf "%s-workload" .Release.Name }}{{- end -}}
{{- define "common.dbSecretName" -}}{{ printf "%s-db-credentials" .Release.Name }}{{- end -}}
{{- define "common.spcName" -}}{{ printf "%s-kv" .Release.Name }}{{- end -}}
