{{/*
Labels qui identifient un composant : utilisés par les selectors des Deployments et des Services.
Usage : include "poll-app.selectorLabels" (dict "root" $ "component" "poll")
*/}}
{{- define "poll-app.selectorLabels" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end }}

{{/*
Labels complets d'un objet. Mêmes arguments que poll-app.selectorLabels.
*/}}
{{- define "poll-app.labels" -}}
{{ include "poll-app.selectorLabels" . }}
app.kubernetes.io/part-of: poll-app
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ .root.Chart.Name }}-{{ .root.Chart.Version }}
{{- end }}

{{/*
Image d'un service de l'app : <registre>/<composant>:<tag>.
Usage : include "poll-app.image" (dict "root" $ "component" "poll")
*/}}
{{- define "poll-app.image" -}}
{{- $registry := required "image.registry est obligatoire (ex : monacr.azurecr.io)" .root.Values.image.registry -}}
{{- $tag := required "image.tag est obligatoire (SHA git, voir deploy/build-push.sh)" .root.Values.image.tag -}}
{{ $registry }}/{{ .component }}:{{ $tag }}
{{- end }}

{{/*
Mot de passe Redis : celui fourni, sinon celui déjà présent dans le cluster, sinon un nouveau.
Réutiliser l'existant évite de changer de mot de passe (et de tout redémarrer) à chaque déploiement.
Le choix est mémorisé dans .Values : ce helper est appelé plusieurs fois par déploiement (le Secret, puis
les annotations checksum/secret). Tiré au hasard à chaque appel, il donnait aux pods une empreinte différente
du Secret réel, et le déploiement suivant redémarrait Redis pour rien.
*/}}
{{- define "poll-app.redisPassword" -}}
{{- if not .Values.redis.password -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace "poll-app-secrets" -}}
{{- if and $existing (index $existing.data "REDIS_PASSWORD") -}}
{{- $_ := set .Values.redis "password" (index $existing.data "REDIS_PASSWORD" | b64dec) -}}
{{- else -}}
{{- $_ := set .Values.redis "password" (randAlphaNum 32) -}}
{{- end -}}
{{- end -}}
{{ .Values.redis.password }}
{{- end }}
