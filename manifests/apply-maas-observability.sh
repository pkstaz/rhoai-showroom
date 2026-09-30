#!/usr/bin/env bash
# Install MaaS observability stack (Tempo, OpenTelemetry, COO, Loki + usage dashboards).
# Based on: https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/07-observability.html
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OBS="${ROOT}/manifests/observability"

# Wait until a CSV whose name matches REGEX exists in NS, then until Succeeded.
wait_csv() {
  local ns="$1"
  local regex="$2"
  local timeout="${3:-300}"
  local end=$((SECONDS + timeout))
  local csv=""

  echo "Waiting for CSV matching /${regex}/ in ${ns}..."
  while (( SECONDS < end )); do
    csv="$(oc get csv -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -E "${regex}" | head -1 || true)"
    if [[ -n "${csv}" ]]; then
      echo "Found ${csv}; waiting Succeeded..."
      oc wait "csv/${csv}" -n "${ns}" \
        --for=jsonpath='{.status.phase}'=Succeeded \
        --timeout="${timeout}s"
      return 0
    fi
    sleep 5
  done
  echo "Timed out waiting for CSV /${regex}/ in ${ns}" >&2
  oc get csv -n "${ns}" || true
  return 1
}

echo "=== 1. Tempo Operator ==="
oc apply -k "${OBS}/tempo"
wait_csv openshift-tempo-operator 'tempo-operator' 300

echo "=== 2. OpenTelemetry Operator ==="
oc apply -k "${OBS}/opentelemetry"
wait_csv openshift-opentelemetry-operator 'opentelemetry-operator' 300

echo "=== 3. Cluster Observability Operator ==="
oc apply -k "${OBS}/coo"
wait_csv openshift-cluster-observability-operator 'cluster-observability-operator' 300

echo "=== 4. DSCI monitoring (Perses dashboards) ==="
oc patch dsci default-dsci --type=merge -p '{
  "spec": {
    "monitoring": {
      "namespace": "redhat-ods-monitoring",
      "metrics": {
        "replicas": 1,
        "storage": {
          "size": "5Gi",
          "retention": "90d"
        }
      },
      "traces": {
        "sampleRatio": "0.1",
        "storage": {
          "backend": "pv",
          "retention": "2160h"
        }
      }
    }
  }
}'
oc wait --for=jsonpath='{.status.phase}'=Ready dsci/default-dsci --timeout=300s || true

echo "=== 5. Gateway telemetry ==="
oc patch maastenantconfig default-tenant -n models-as-a-service \
  --type=merge -p '{"spec":{"telemetry":{"enabled":true}}}'

echo "=== 6. Loki Operator ==="
oc apply -k "${OBS}/loki"
wait_csv openshift-operators-redhat 'loki-operator' 300

# CRDs del Loki Operator: el CSV queda Succeeded antes de que los CRDs esten
# Established; sin lokistacks.loki.grafana.com el apply del paso 7 falla.
echo "Waiting for CRD lokistacks.loki.grafana.com (Established)..."
for i in $(seq 1 60); do
  oc get crd lokistacks.loki.grafana.com \
    -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null \
    | grep -q True && break
  sleep 5
done
oc get crd lokistacks.loki.grafana.com >/dev/null 2>&1 || {
  echo "ERROR: CRD lokistacks.loki.grafana.com no existe (Loki Operator sin CRDs)"; exit 1; }

echo "=== 7. MinIO + LokiStack (usage dashboards) ==="
# El primer apply puede chocar con CRDs recien establecidos; reintenta hasta
# que el CR LokiStack exista.
oc apply -k "${OBS}/usage-logging" || true
for i in 1 2 3 4 5 6; do
  oc get lokistack usage -n redhat-ods-monitoring >/dev/null 2>&1 && break
  echo "LokiStack usage no creado (try $i); re-aplicando..."
  sleep 10
  oc apply -k "${OBS}/usage-logging" || true
done
oc get lokistack usage -n redhat-ods-monitoring >/dev/null || {
  echo "ERROR: LokiStack usage no se creo; revisa:"; \
  echo "  oc get crd lokistacks.loki.grafana.com"; \
  echo "  oc get csv -n openshift-operators-redhat | grep loki"; exit 1; }

# StorageClass gp3-csi es del OpenTLC; en otro cluster cae al default.
if ! oc get storageclass gp3-csi >/dev/null 2>&1; then
  DEFAULT_SC=$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}')
  if [[ -n "$DEFAULT_SC" && "$DEFAULT_SC" != "gp3-csi" ]]; then
    echo "gp3-csi no existe; usando StorageClass default ${DEFAULT_SC}"
    oc patch lokistack usage -n redhat-ods-monitoring --type=merge \
      -p "{\"spec\":{\"storageClassName\":\"${DEFAULT_SC}\"}}"
  fi
fi

oc wait --for=condition=available deployment/minio -n redhat-ods-monitoring --timeout=300s
oc wait job/minio-create-bucket -n redhat-ods-monitoring --for=condition=complete --timeout=300s || true
oc wait lokistack/usage -n redhat-ods-monitoring \
  --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True --timeout=600s || \
  echo "WARN: LokiStack usage no Ready; revisa 'oc get lokistack usage -n redhat-ods-monitoring -o yaml' y sus events"

echo "=== 8. Enable usageLogging ==="
oc patch configs.maas.opendatahub.io default --type=merge \
  -p '{"spec":{"usageLogging":true}}'

echo "=== Verify ==="
oc get csv -n openshift-tempo-operator | grep tempo || true
oc get csv -n openshift-opentelemetry-operator | grep opentelemetry || true
oc get csv -n openshift-cluster-observability-operator | grep cluster-observability || true
oc get csv -n openshift-operators-redhat | grep loki || true
oc get telemetrypolicies.extensions.kuadrant.io -n openshift-ingress || true
oc get telemetry.telemetry.istio.io -n openshift-ingress || true
oc get persesdashboard -n redhat-ods-monitoring 2>/dev/null || true
oc get envoyfilter maas-model-access-logs -n openshift-ingress 2>/dev/null || true
echo "Done. Open RHOAI → Observe & monitor → Dashboard"
