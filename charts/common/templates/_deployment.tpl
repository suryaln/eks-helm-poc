{{- define "common.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "common.fullname" . }}
  labels:
    {{- include "common.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "common.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "common.selectorLabels" . | nindent 8 }}
    spec:
      {{- if .Values.useIrsa }}
      serviceAccountName: {{ include "common.serviceAccountName" . }}
      {{- else }}
      automountServiceAccountToken: false
      {{- end }}
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      {{- if .Values.waitForDb }}
      initContainers:
        - name: wait-for-db
          image: busybox:1.36
          command: ["sh", "-c", "until nc -z {{ .Values.dbHost | default (print .Release.Name "-database") }} {{ .Values.dbPort }}; do echo waiting for db; sleep 2; done"]
          securityContext:
            {{- toYaml .Values.containerSecurityContext | nindent 12 }}
          resources:
            limits: {cpu: 50m, memory: 32Mi}
            requests: {cpu: 10m, memory: 16Mi}
      {{- end }}
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          {{- with .Values.command }}
          command:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.args }}
          args:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          ports:
            - name: http
              containerPort: {{ .Values.service.targetPort }}
          {{- if .Values.env }}
          env:
            {{- range .Values.env }}
            - name: {{ .name }}
              {{- if .fromDbSecret }}
              valueFrom:
                secretKeyRef:
                  name: {{ include "common.dbSecretName" $ }}
                  key: {{ .fromDbSecret }}
              {{- else }}
              value: {{ tpl (toString .value) $ | quote }}
              {{- end }}
            {{- end }}
          {{- end }}
          {{- with .Values.livenessProbe }}
          livenessProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.readinessProbe }}
          readinessProbe:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          securityContext:
            {{- toYaml .Values.containerSecurityContext | nindent 12 }}
          {{- if .Values.secretsStore.enabled }}
          volumeMounts:
            - name: secrets-store
              mountPath: /mnt/secrets-store
              readOnly: true
          {{- end }}
      {{- if .Values.secretsStore.enabled }}
      volumes:
        - name: secrets-store
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: {{ include "common.spcName" . }}
      {{- end }}
{{- end -}}
