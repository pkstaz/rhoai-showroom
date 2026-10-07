#!/usr/bin/env bash
# Módulo 12.3 — Lanza las dos evaluaciones de seguridad sobre el modelo GPU Qwen3-14B-AWQ:
#   • Context-aware vulnerability scan   (benchmark `intents`, provider garak)
#   • OWASP LLM top 10 risk scan         (benchmark `owasp_llm_top10`, provider garak)
# Todo queda registrado en el experimento MLflow qwen3-14b-evals-gpu
# (créalo primero con: bash manifests/apply-mlflow-audit.sh).
# Uso (desde la raíz del repo, con `oc` logueado):
#   bash manifests/apply-evals-gpu.sh            # dry-run: imprime los payloads
#   SUBMIT=1 bash manifests/apply-evals-gpu.sh   # lanza los dos jobs
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DSP_NS="${DSP_NS:-llm}"
EXPERIMENT_NAME="${EXPERIMENT_NAME:-qwen3-14b-evals-gpu}"
MODEL_ID="${MODEL_ID:-publishers/llm/models/qwen3-14b-awq}"
API_KEY_SECRET="${API_KEY_SECRET:-maas-eval-api-key}"
SUBMIT="${SUBMIT:-0}"
WORKSPACE="${WORKSPACE:-llm}"
PF_PORT="${PF_PORT:-18443}"
OUT_DIR="${OUT_DIR:-/tmp/rhoai-evals-gpu}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq no instalado (módulo 0.1)"; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "ERROR: oc no logueado"; exit 1; }

echo "=== Prerrequisitos ==="

oc get evalhub evalhub -n evalhub >/dev/null 2>&1 || {
  echo "ERROR: EvalHub no existe — ejecuta antes: bash manifests/apply-evalhub.sh (módulo 12.00)"
  exit 1
}

LLM_READY="$(oc get llminferenceservices.serving.kserve.io qwen3-14b-awq -n "${DSP_NS}" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [[ "${LLM_READY}" != "True" ]]; then
  echo "ERROR: qwen3-14b-awq no está Ready en ${DSP_NS} — completa el módulo 8.2 (GPU)"
  oc get llminferenceservices.serving.kserve.io -n "${DSP_NS}" 2>/dev/null || true
  exit 1
fi
echo "  EvalHub OK · llminference qwen3-14b-awq Ready"

for ns in "${DSP_NS}" evalhub; do
  if ! oc get secret "${API_KEY_SECRET}" -n "${ns}" >/dev/null 2>&1; then
    echo "ERROR: falta el secret ${API_KEY_SECRET} en ${ns} — ver 12.00 (Fallback MaaS local)"
    exit 1
  fi
done
echo "  Secret ${API_KEY_SECRET} presente en ${DSP_NS} y evalhub"

TOKEN="$(oc whoami -t)"
CLUSTER_DOMAIN="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')"
ENDPOINT="${ENDPOINT:-https://maas.${CLUSTER_DOMAIN}/v1}"

EVALHUB_HOST="$(oc get route -n evalhub -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"
if [[ -z "${EVALHUB_HOST}" ]]; then
  EVALHUB_URL="https://evalhub.evalhub.svc.cluster.local:8443"
else
  EVALHUB_URL="https://${EVALHUB_HOST}"
fi

# --- Experimento MLflow: get-or-create (port-forward corto) -------------------
if [[ -z "${MLFLOW_URL:-}" ]]; then
  MLFLOW_URL="https://localhost:${PF_PORT}/mlflow"
  probe() {
    curl -sk -m 3 "${MLFLOW_URL}/api/2.0/mlflow/experiments/search" \
      -H "X-MLFLOW-WORKSPACE: ${WORKSPACE}" -H "Authorization: Bearer ${TOKEN}" \
      -H 'Content-Type: application/json' -d '{"max_results":1}' >/dev/null 2>&1
  }
  if ! probe; then
    oc port-forward -n redhat-ods-applications svc/mlflow "${PF_PORT}:8443" >/dev/null 2>&1 &
    PF_PID=$!
    trap 'kill "${PF_PID}" 2>/dev/null || true' EXIT
    for _ in $(seq 1 30); do probe && break; sleep 1; done
  fi
fi
EXP_JSON="$(curl -sk -X POST "${MLFLOW_URL}/api/2.0/mlflow/experiments/search" \
  -H "X-MLFLOW-WORKSPACE: ${WORKSPACE}" -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' -d '{"max_results":1000}' 2>/dev/null || true)"
EXP_ID="$(printf '%s' "${EXP_JSON}" | jq -r --arg n "${EXPERIMENT_NAME}" \
  '[.experiments[]? | select(.name==$n and .lifecycle_stage=="active")][0].experiment_id // empty' 2>/dev/null || true)"
if [[ -z "${EXP_ID}" ]]; then
  echo
  echo "AVISO: el experimento ${EXPERIMENT_NAME} no existe en MLflow."
  echo "       Ejecuta antes: bash manifests/apply-mlflow-audit.sh (deja el audit completo)"
  exit 1
fi
echo "  Experimento MLflow ${EXPERIMENT_NAME} (id ${EXP_ID}) en workspace ${WORKSPACE}"

# --- Payloads -----------------------------------------------------------------
# Nota: en simple mode EvalHub monta el secreto como token-ref (`api-key:ref`)
# y todas las llamadas al modelo deben pasar por el sidecar de EvalHub
# (localhost:8080), que inyecta la credencial real. El sidecar reescribe
# además model.url del job a esta misma dirección.
SIDECAR_URL="http://localhost:8080/v1"
mkdir -p "${OUT_DIR}"
CONTEXT_JSON="${OUT_DIR}/qwen3-14b-context-aware-scan.json"
OWASP_JSON="${OUT_DIR}/qwen3-14b-owasp-top10-scan.json"

cat >"${CONTEXT_JSON}" <<EOF
{
  "name": "qwen3-14b-context-aware-scan",
  "model": {
    "url": "${ENDPOINT}",
    "name": "${MODEL_ID}",
    "auth": { "secret_ref": "${API_KEY_SECRET}" }
  },
  "benchmarks": [
    {
      "id": "intents",
      "provider_id": "garak",
      "parameters": {
        "execution_mode": "simple",
        "sdg_max_concurrency": 6,
        "sdg_max_tokens": 512,
        "intents_models": {
          "judge":     { "url": "${SIDECAR_URL}", "name": "${MODEL_ID}" },
          "sdg":       { "url": "${SIDECAR_URL}", "name": "hosted_vllm/${MODEL_ID}" }
        }
      }
    }
  ],
  "experiment": { "name": "${EXPERIMENT_NAME}" }
}
EOF

cat >"${OWASP_JSON}" <<EOF
{
  "name": "qwen3-14b-owasp-top10-scan",
  "model": {
    "url": "${ENDPOINT}",
    "name": "${MODEL_ID}",
    "auth": { "secret_ref": "${API_KEY_SECRET}" }
  },
  "benchmarks": [
    {
      "id": "owasp_llm_top10",
      "provider_id": "garak",
      "parameters": { "execution_mode": "simple" }
    }
  ],
  "experiment": { "name": "${EXPERIMENT_NAME}" }
}
EOF

echo
echo "EvalHub: ${EVALHUB_URL}  (X-Tenant: ${DSP_NS})"
echo "Endpoint modelo: ${ENDPOINT}  ·  ${MODEL_ID}"
echo
echo "Payload 1 — Context-aware vulnerability scan (intents): ${CONTEXT_JSON}"
jq . "${CONTEXT_JSON}"
echo "Payload 2 — OWASP LLM top 10 risk scan: ${OWASP_JSON}"
jq . "${OWASP_JSON}"

submit_job() {
  local file="$1"
  local resp
  resp="$(curl -sk -X POST "${EVALHUB_URL}/api/v1/evaluations/jobs" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "X-Tenant: ${DSP_NS}" \
    -H 'Content-Type: application/json' \
    -d @"${file}")"
  printf '%s' "${resp}" | jq -e 'has("error") or has("error_code")' >/dev/null 2>&1 && {
    echo "ERROR al lanzar $(basename "${file}"): ${resp}" >&2
    return 1
  }
  printf '%s' "${resp}" | jq -r '"  job: \(.resource.id // .id // "?")"'
}

if [[ "${SUBMIT}" == "1" ]]; then
  ACTIVE_JOBS="$(curl -sk "${EVALHUB_URL}/api/v1/evaluations/jobs?limit=20" \
    -H "Authorization: Bearer ${TOKEN}" -H "X-Tenant: ${DSP_NS}" 2>/dev/null \
    | jq -r '[.jobs[]?.resource | select(.state | tostring | test("running|pending|queued"; "i"))] | length' 2>/dev/null || echo 0)"
  if [[ "${ACTIVE_JOBS}" != "0" ]]; then
    echo
    echo "AVISO: hay ${ACTIVE_JOBS} job(s) de evaluación activos. Ejecutar los dos scans a la vez"
    echo "       comparte la GPU y puede agotar el timeout del sidecar en la fase SDG."
    echo "       Recomendado: esperar a que termine el job activo (UI Evaluations o curl de arriba)."
  fi
  echo
  echo "=== Lanzando evaluaciones (los jobs son asíncronos) ==="
  submit_job "${CONTEXT_JSON}"
  submit_job "${OWASP_JSON}"
  echo
  echo "Seguimiento:"
  echo "  UI: Dashboard → Develop & train → Evaluations → proyecto ${DSP_NS}"
  echo "  CLI: curl -sk '${EVALHUB_URL}/api/v1/evaluations/jobs?limit=10' \\"
  echo "         -H 'Authorization: Bearer \$(oc whoami -t)' -H 'X-Tenant: ${DSP_NS}' | jq"
  echo "  MLflow: experimento ${EXPERIMENT_NAME} (runs por job con attack_success_rate y artefactos)"
  echo
  echo "Tiempos: OWASP ~30 min (12045 ejemplos); Context-aware incluye fase SDG (~30–90 min)."
  echo "La primera vez el pod descarga la imagen Garak (minutos en Pending)."
else
  echo
  echo "Dry-run: no se ha lanzado nada."
  echo "Lanza con:  SUBMIT=1 bash manifests/apply-evals-gpu.sh"
fi
