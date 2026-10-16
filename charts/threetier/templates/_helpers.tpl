{{/* Service name of a tier: <release>-<tier> */}}
{{- define "threetier.svcName" -}}
{{- printf "%s-%s" .root.Release.Name .tier -}}
{{- end -}}

{{/* Global ingress paths: only emits paths whose tier is enabled */}}
{{- define "threetier.ingressPaths" -}}
{{- $root := . -}}
{{- range .Values.ingress.paths }}
{{- $tier := index $root.Values .service }}
{{- if $tier.enabled }}
- path: {{ .path }}
  pathType: {{ .pathType | default "Prefix" }}
  backend:
    service:
      name: {{ include "threetier.svcName" (dict "root" $root "tier" .service) }}
      port:
        number: {{ $tier.service.port }}
{{- end }}
{{- end }}
{{- end -}}
