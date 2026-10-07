#!/usr/bin/env bash
# Plugin de consola OpenShift: gestion de agentes OpenCode (entornos).
# Construye la imagen nginx con el dist/ pre-compilado (npm run build en
# console-plugin/openshell-manager), la despliega en openshell-users y registra
# el ConsolePlugin en el console del cluster.
#
# Uso desde la raiz del repo (oc login ya hecho):
#   npm install && npm run build   # solo si cambio el frontend
#   bash manifests/apply-opencode-plugin.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
NS="${NS:-openshell-users}"
PLUGIN=openshell-manager
APP=openshell-manager-plugin
IMAGE="image-registry.openshift-image-registry.svc:5000/${NS}/${APP}:latest"
PORT=9443

[[ -d console-plugin/openshell-manager/dist ]] || { echo "ERROR: falta dist/ (npm install && npm run build en console-plugin/openshell-manager)"; exit 1; }
oc get ns "$NS" >/dev/null

echo "=== BuildConfig + build (${NS}/${APP}) ==="
if ! oc -n "$NS" get imagestream "${APP}" >/dev/null 2>&1; then
  oc -n "$NS" new-build --binary --name="${APP}" --strategy=docker --to="${APP}:latest" 2>/dev/null || true
fi
oc -n "$NS" start-build "${APP}" --from-dir="console-plugin/openshell-manager" --follow --wait

echo "=== nginx TLS + Service + ConsolePlugin ==="
oc -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PLUGIN}
  namespace: ${NS}
data:
  nginx.conf: |
    error_log /dev/stdout info;
    events {}
    http {
      access_log         /dev/stdout;
      include            /etc/nginx/mime.types;
      default_type       application/octet-stream;
      keepalive_timeout  65;
      server {
        listen              ${PORT} ssl;
        listen              [::]:${PORT} ssl;
        ssl_certificate     /var/cert/tls.crt;
        ssl_certificate_key /var/cert/tls.key;
        root                /usr/share/nginx/html;
      }
    }
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP}
  namespace: ${NS}
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: ${PLUGIN}-cert
spec:
  ports:
    - name: ${PORT}-tcp
      protocol: TCP
      port: ${PORT}
      targetPort: ${PORT}
  selector:
    app: ${PLUGIN}
  type: ClusterIP
EOF

oc -n "$NS" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP}
  namespace: ${NS}
  labels:
    app: ${PLUGIN}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PLUGIN}
  template:
    metadata:
      labels:
        app: ${PLUGIN}
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: nginx
          image: ${IMAGE}
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          ports:
            - containerPort: ${PORT}
              protocol: TCP
          resources:
            requests:
              cpu: 10m
              memory: 64Mi
            limits:
              memory: 128Mi
          volumeMounts:
            - name: cert
              readOnly: true
              mountPath: /var/cert
            - name: nginx-conf
              readOnly: true
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
      volumes:
        - name: cert
          secret:
            secretName: ${PLUGIN}-cert
            defaultMode: 420
        - name: nginx-conf
          configMap:
            name: ${PLUGIN}
            defaultMode: 420
EOF

oc -n "$NS" apply -f - <<EOF
apiVersion: console.openshift.io/v1
kind: ConsolePlugin
metadata:
  name: ${PLUGIN}
spec:
  displayName: OpenShell Manager
  i18n:
    loadType: Preload
  backend:
    type: Service
    service:
      name: ${APP}
      namespace: ${NS}
      port: ${PORT}
      basePath: /
EOF

echo "=== Registrar en el console del cluster ==="
if ! oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins[*]}' | grep -qw "${PLUGIN}"; then
  oc patch consoles.operator.openshift.io cluster --type=json \
    -p '[{"op":"add","path":"/spec/plugins/-","value":"'"${PLUGIN}"'"}]'
else
  echo "Plugin ${PLUGIN} ya registrado"
fi

oc -n "$NS" rollout status "deploy/${APP}" --timeout=300s || true
# El tag de imagen es :latest y el pod spec no cambia entre builds: fuerza el
# rollout para que el console sirva el dist nuevo.
oc -n "$NS" rollout restart "deploy/${APP}" 2>/dev/null || true
oc -n "$NS" rollout status "deploy/${APP}" --timeout=300s || true
echo
echo "Hard refresh del console (Ctrl+Shift+R). Menu OpenCode → Manager."
oc -n "$NS" get pods,consoleplugin -l app=${PLUGIN} 2>/dev/null || oc get consoleplugin ${PLUGIN}
