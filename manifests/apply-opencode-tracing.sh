#!/usr/bin/env bash
# Habilita MLflow prompt tracing (autolog) en los agentes OpenCode por usuario
# (proyecto opencode-users): el plugin @mlflow/opencode captura cada sesion
# (prompts, respuestas, tool usage, token usage) al experimento MLflow
# agent-sessions (workspace llm) usando el token del SA del pod
# (MLFLOW_TRACKING_AUTH=kubernetes + header X-MLFLOW-WORKSPACE).
#
# Requiere MLflow desplegado (apply-evalhub.sh) y oc login hecho.
# Uso desde la raiz del repo:
#   bash manifests/apply-opencode-tracing.sh
#   USERS="jero rodri" REBUILD=0 bash manifests/apply-opencode-tracing.sh
#
# Idempotente: se puede re-ejecutar (REBUILD=0 para saltar el rebuild de la imagen).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
NS="${NS:-opencode-users}"
USERS="${USERS:-jero rodri pablo}"
APP=opencode-agent
EXPERIMENT="${EXPERIMENT:-agent-sessions}"
WORKSPACE="${WORKSPACE:-llm}"
REBUILD="${REBUILD:-1}"

oc get ns "$NS" >/dev/null

echo "=== RBAC: SA ${NS}/${APP} en el workspace ${WORKSPACE} ==="
# MLflow kubernetes auth (self_subject_access_review): el token del cliente se
# valida contra permisos en el namespace del workspace (mismo patron que evalhub).
oc -n "${WORKSPACE}" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: opencode-agent-mlflow-workspace-${WORKSPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
subjects:
  - kind: ServiceAccount
    name: ${APP}
    namespace: ${NS}
EOF

echo "=== Experimento MLflow ${EXPERIMENT} (workspace ${WORKSPACE}) ==="
TOKEN=$(oc -n "$NS" create token "${APP}" --duration=10m)
EXP_ID=$(oc exec -n redhat-ods-applications deploy/mlflow -- sh -c 'curl -sk -H "Authorization: Bearer '"$TOKEN"'" -H "X-MLFLOW-WORKSPACE: '"${WORKSPACE}"'" "https://localhost:8443/mlflow/api/2.0/mlflow/experiments/get-by-name?experiment_name='"${EXPERIMENT}"'"' 2>/dev/null | grep -oE '"experiment_id": *"[0-9]+"' | grep -oE '[0-9]+' || true)
if [[ -z "$EXP_ID" ]]; then
  EXP_ID=$(oc exec -n redhat-ods-applications deploy/mlflow -- sh -c 'curl -sk -X POST -H "Authorization: Bearer '"$TOKEN"'" -H "Content-Type: application/json" -H "X-MLFLOW-WORKSPACE: '"${WORKSPACE}"'" "https://localhost:8443/mlflow/api/2.0/mlflow/experiments/create" --data "{\"name\":\"'"${EXPERIMENT}"'\"}"' | grep -oE '"experiment_id": *"[0-9]+"' | grep -oE '[0-9]+')
fi
[[ -z "$EXP_ID" ]] && { echo "ERROR: no se pudo crear/encontrar el experimento ${EXPERIMENT}"; exit 1; }
echo "  MLFLOW_EXPERIMENT_ID=${EXP_ID}"

if [[ "$REBUILD" == "1" ]]; then
  echo "=== Rebuild de la imagen ${APP} (plugin @mlflow/opencode) ==="
  oc -n "$NS" get imagestream "${APP}" >/dev/null 2>&1 || \
    oc -n "$NS" new-build --binary --name="${APP}" --strategy=docker --to="${APP}:latest" 2>/dev/null || true
  oc -n "$NS" start-build "${APP}" --from-dir="manifests/agents/opencode" --follow --wait
else
  echo "=== REBUILD=0: se omite el rebuild de la imagen ==="
fi

echo "=== Re-render + despliegue de los agentes (rollout automático) ==="
# Con imagePullPolicy: Always, el rollout del env change descarga la imagen
# recién reconstruida: un solo rollout.
MLFLOW_EXPERIMENT_ID="${EXP_ID}" bash manifests/apply-opencode-users.sh

echo
echo "=== MLflow prompt tracing activo ==="
echo "  Plugin:        @mlflow/opencode (captura al idle de cada turno)"
echo "  Experimento:   ${EXPERIMENT} (ID ${EXP_ID}, workspace ${WORKSPACE})"
echo "  Auth:          token del SA ${NS}/${APP} (MLFLOW_TRACKING_AUTH=kubernetes)"
echo "  Verifica en la MLflow UI (Traces) del dashboard RHOAI: prompts, respuestas y token usage."
