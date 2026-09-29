{{- define "zenml-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "zenml-stack.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "zenml-stack.labels" -}}
helm.sh/chart: {{ include "zenml-stack.name" . }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "zenml-stack.selectorLabels" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "zenml-stack.orchestratorServiceAccount" -}}
{{- .Values.orchestrator.serviceAccountName }}
{{- end }}

{{/*
S4 fullname (matches s4.fullnameOverride / fullnameOverride: s4)
*/}}
{{- define "s4.fullname" -}}
s4
{{- end }}

{{/*
S4 credentials Secret name — chart creates {fullname}-credentials with AWS_* keys
*/}}
{{- define "s4.secretName" -}}
{{- printf "%s-credentials" (include "s4.fullname" .) }}
{{- end }}

{{/*
S4 S3 API port
*/}}
{{- define "s4.apiPort" -}}
7480
{{- end }}

{{/*
S4 web UI port (readiness probe path /api)
*/}}
{{- define "s4.uiPort" -}}
5000
{{- end }}
