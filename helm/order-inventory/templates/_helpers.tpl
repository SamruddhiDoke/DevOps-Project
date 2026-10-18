{{- define "oi.labels" -}}
app.kubernetes.io/part-of: order-inventory
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/* Full image reference; fails rendering if no immutable tag was supplied. Args: (list $ repository) */}}
{{- define "oi.image" -}}
{{- $root := index . 0 -}}
{{- $repo := index . 1 -}}
{{- $tag := required "image.tag is required (immutable build tag, never latest)" $root.Values.image.tag -}}
{{- if eq $tag "latest" -}}
{{- fail "image.tag must be an immutable build tag, not latest" -}}
{{- end -}}
{{- if $root.Values.image.registry -}}
{{ printf "%s/%s:%s" $root.Values.image.registry $repo $tag }}
{{- else -}}
{{ printf "%s:%s" $repo $tag }}
{{- end -}}
{{- end }}

{{- define "oi.podSecurityContext" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end }}
