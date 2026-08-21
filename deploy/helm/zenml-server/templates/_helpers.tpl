{{- define "zenml-server.databasePassword" -}}
{{- $secretName := .Values.database.passwordSecretName -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace $secretName -}}
{{- if and $existing (index $existing.data "password") -}}
{{- index $existing.data "password" | b64dec -}}
{{- else if .Values.database.password -}}
{{- .Values.database.password -}}
{{- else -}}
{{- randAlphaNum 48 -}}
{{- end -}}
{{- end }}

{{- define "zenml-server.databaseRootPassword" -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace .Values.database.passwordSecretName -}}
{{- if and $existing (index $existing.data "mysql-root-password") -}}
{{- index $existing.data "mysql-root-password" | b64dec -}}
{{- else if .Values.database.rootPassword -}}
{{- .Values.database.rootPassword -}}
{{- else -}}
{{- randAlphaNum 48 -}}
{{- end -}}
{{- end }}
