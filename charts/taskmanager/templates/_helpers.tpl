{{/*
─── _helpers.tpl ─────────────────────────────────────────────────────────────
Reusable named template definitions (partials).
Files prefixed with _ are NOT rendered as standalone Kubernetes manifests.
─────────────────────────────────────────────────────────────────────────────
*/}}

{{/*
Expand the chart name.
*/}}
{{- define "taskmanager.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a fully qualified release name.
Truncated to 63 chars to satisfy DNS label constraints.
*/}}
{{- define "taskmanager.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels applied to every resource.
Includes environment label for easy filtering across environments.
*/}}
{{- define "taskmanager.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "taskmanager.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
environment: {{ .Values.environment }}
{{- end }}

{{/*
Selector labels — used in matchLabels and service selectors.
Must remain stable; do NOT include version or environment here.
*/}}
{{- define "taskmanager.selectorLabels" -}}
app.kubernetes.io/name: {{ include "taskmanager.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Frontend-specific selector labels.
*/}}
{{- define "taskmanager.frontend.selectorLabels" -}}
{{ include "taskmanager.selectorLabels" . }}
tier: frontend
{{- end }}

{{/*
Backend-specific selector labels.
*/}}
{{- define "taskmanager.backend.selectorLabels" -}}
{{ include "taskmanager.selectorLabels" . }}
tier: backend
{{- end }}

{{/*
Renders the chart version string for use in image tags or annotations.
*/}}
{{- define "taskmanager.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}
