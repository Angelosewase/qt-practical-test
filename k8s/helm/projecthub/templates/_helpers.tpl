{{/* Labels for an object of component .name. The selector uses only app.kubernetes.io/name, as in k8s/. */}}
{{- define "projecthub.labels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
{{- end }}

{{- define "projecthub.image" -}}
{{ .repository }}:{{ .tag }}
{{- end }}

{{/* Hash of the rendered ConfigMaps: a config change rolls the API and gateway pods (D-CORS-3). */}}
{{- define "projecthub.configHash" -}}
{{ include (print $.Template.BasePath "/10-config.yaml") . | sha256sum | trunc 16 }}
{{- end }}
