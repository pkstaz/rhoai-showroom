#!/usr/bin/env bash
# Habilitar MaaS (modulo 4) end-to-end:
#   operadores pre-requisito (Connectivity Link, Leader Worker Set) si faltan
#   -> GatewayClass + Istio -> Kuadrant -> Postgres + maas-db-config
#   -> Gateway maas-default-gateway -> modelsAsAService: Managed en el DSC
#   -> auto-fix Authorino (service CA + gRPC TLS) + smoke test /maas-api.
#
# Uso desde otro proyecto (con oc login ya hecho en el cluster):
#   git clone git@github.com:pkstaz/rhoai-showroom.git
#   bash rhoai-showroom/manifests/apply-maas.sh
#
# Flags:
#   --skip-operator   Operadores pre-requisito ya instalados (modulo 2)
#
# Idempotente: se puede re-ejecutar. Los manifiestos declarativos de este repo
# son la fuente de verdad lista para GitOps:
#   oc apply -k rhoai-showroom/manifests/maas   (GatewayClass + Kuadrant + Postgres)
# El Gateway y el DSC dependen de valores del cluster (dominio, certificado,
# nombre del DSC); para GitOps pasarian a ser valores parametrizados.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKIP_OPERATOR=0
[[ "${1:-}" == "--skip-operator" ]] && SKIP_OPERATOR=1

oc whoami >/dev/null 2>&1 || { echo "ERROR: no hay sesion de cluster (oc login)"; exit 1; }

# Espera a que el CSV que matchee el pattern quede Succeeded.
wait_csv_succeeded() {
  local pattern="$1" ns="$2" csv="" phase=""
  for i in $(seq 1 60); do
    csv=$(oc get csv -n "$ns" --no-headers 2>/dev/null \
      | grep -i "$pattern" | awk '{print $1}' | head -1 || true)
    [[ -z "$csv" ]] && { echo "esperando CSV ($pattern) en $ns (try $i)"; sleep 10; continue; }
    phase=$(oc get csv "$csv" -n "$ns" -o jsonpath='{.status.phase}')
    [[ "$phase" == "Succeeded" ]] && { echo "CSV $csv: Succeeded"; return 0; }
    echo "CSV $csv: $phase (try $i)"
    sleep 10
  done
  echo "ERROR: CSV $pattern no quedo Succeeded en $ns"; return 1
}

# Instala un operador (subscription YAML) si ningun CSV lo cubre ya.
ensure_operator() {
  local label="$1" pattern="$2" ns="$3" yaml="$4" csv=""
  csv=$(oc get csv -n "$ns" --no-headers 2>/dev/null \
    | grep -i "$pattern" | awk '{print $1}' | head -1 || true)
  if [[ -z "$csv" ]]; then
    echo "=== Operator $label ==="
    oc apply -f "$yaml"
  else
    echo "=== Operator $label ($csv ya instalado) ==="
  fi
  wait_csv_succeeded "$pattern" "$ns"
}

# --- 0. Operadores pre-requisito (modulo 2) ----------------------------------
if [[ $SKIP_OPERATOR -eq 0 ]]; then
  ensure_operator "Connectivity Link" connectivity openshift-operators \
    manifests/operators/connectivity-link/subscription.yaml
  ensure_operator "Leader Worker Set" leader-worker openshift-lws-operator \
    manifests/operators/leader-worker-set/subscription.yaml
fi

# --- 1. GatewayClass + Istio (data plane) ------------------------------------
echo "=== GatewayClass + Service Mesh (istiod-openshift-gateway) ==="
oc apply -f manifests/maas/gatewayclass.yaml
oc wait --for=condition=Accepted gatewayclass/openshift-default --timeout=5m
oc rollout status -n openshift-ingress deploy/istiod-openshift-gateway --timeout=10m

# --- 2. Kuadrant (no crear antes de Istio; ver troubleshooting del modulo 4) -
echo "=== Kuadrant (kuadrant-system) ==="
oc get ns kuadrant-system >/dev/null 2>&1 || oc create ns kuadrant-system
oc apply -f manifests/maas/kuadrant.yaml
if ! oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready --timeout=5m 2>/dev/null; then
  echo "Kuadrant no Ready: reinicio del controller (provider Gateway API no detectado)"
  oc delete pod -n openshift-operators \
    -l control-plane=controller-manager \
    --field-selector=status.phase=Running
  oc rollout status -n openshift-operators deploy/kuadrant-operator-controller-manager --timeout=3m
  oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready --timeout=5m
fi

# --- 3. Postgres + secret maas-db-config --------------------------------------
echo "=== Postgres + maas-db-config (redhat-ai-gateway-infra) ==="
oc apply -f manifests/maas/maas-postgres.yaml
oc wait -n redhat-ai-gateway-infra --for=condition=Available deploy/maas-postgres --timeout=5m

# --- 4. Gateway maas-default-gateway ------------------------------------------
echo "=== Gateway maas-default-gateway ==="
bash manifests/apply-maas-gateway.sh

# --- 5. modelsAsAService: Managed en el DSC -----------------------------------
echo "=== modelsAsAService: Managed (DSC) ==="
DSC=$(oc get dsc -o name | head -1)
echo "DSC: $DSC"
oc patch "$DSC" --type merge -p '{
  "spec": {
    "components": {
      "aigateway": {
        "managementState": "Managed",
        "modelsAsAService": { "managementState": "Managed" }
      }
    }
  }
}'
oc wait --for=condition=Ready "$DSC" --timeout=15m || \
  echo "DSC aun no Ready; revisa los pods (el despliegue de MaaS tarda)"

# --- 6. Salud maas-api + auto-fix Authorino ------------------------------------
# Sin gRPC TLS alineado, POST /maas-api/v1/api-keys devuelve texto plano
# ("Internal Server Error") y el dashboard falla con:
#   - API Key:   unmarshall: invalid character 'I' looking for beginning of value
#   - AI Assets: Models as a Service could not be loaded. Only models from
#                available sources are shown.
# Causa: Envoy habla TLS con Authorino :50051 y el listener esta en plaintext
# (ademas falta el service CA para que Authorino valide maas-api HTTPS).
echo "=== maas-api / maas-controller (redhat-ods-applications) ==="
oc wait -n redhat-ods-applications --for=condition=Available deploy/maas-api --timeout=10m || true
oc wait -n redhat-ods-applications --for=condition=Available deploy/maas-controller --timeout=10m || true

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

maas_api_check() {
  curl -sk -X POST "https://maas.${CLUSTER_DOMAIN}/maas-api/v1/api-keys" \
    -H "Authorization: Bearer $(oc whoami -t)" \
    -H "Content-Type: application/json" \
    -d '{"name":"maas-install-check","expiresIn":"1h"}' 2>/dev/null
}

apply_authorino_fixes() {
  local NS="${AUTHORINO_NAMESPACE:-kuadrant-system}"
  local NAME="${AUTHORINO_NAME:-authorino}"

  echo "=== Auto-fix Authorino: service CA + gRPC TLS (${NS}/${NAME}) ==="

  # CA: monta el service-CA para que Authorino valide maas-api HTTPS (:8443).
  # Sin esto, /v1/models y chat responden AUTH_FAILURE.
  oc patch authorino "${NAME}" -n "${NS}" --type=merge -p '{
    "spec": {
      "volumes": {
        "defaultMode": 420,
        "items": [
          {
            "name": "openshift-service-ca",
            "mountPath": "/etc/pki/tls/certs/maas-ca",
            "configMaps": ["openshift-service-ca.crt"]
          }
        ]
      }
    }
  }'
  oc set env "deploy/${NAME}" -n "${NS}" \
    SSL_CERT_DIR=/etc/ssl/certs:/etc/pki/tls/certs:/etc/pki/tls/certs/maas-ca
  oc rollout status "deploy/${NAME}" -n "${NS}" --timeout=120s

  # gRPC TLS: el EnvoyFilter openshift-ai-inference-authn-ssl hace que el wasm
  # hable TLS con Authorino :50051; el listener debe quedar en TLS tambien.
  # DestinationRule tls.mode=DISABLE y MERGE->raw_buffer NO lo arreglan.
  oc annotate svc authorino-authorino-authorization -n "${NS}" \
    "service.beta.openshift.io/serving-cert-secret-name=authorino-server-cert" --overwrite
  for _ in $(seq 1 30); do
    oc get secret authorino-server-cert -n "${NS}" >/dev/null 2>&1 && break
    sleep 2
  done
  oc get secret authorino-server-cert -n "${NS}" >/dev/null
  oc patch authorino "${NAME}" -n "${NS}" --type=merge -p '{
    "spec": {
      "listener": {
        "tls": {
          "enabled": true,
          "certSecretRef": { "name": "authorino-server-cert" }
        }
      }
    }
  }'
  oc rollout status "deploy/${NAME}" -n "${NS}" --timeout=180s

  # Reinicio del gateway para que Envoy reconecte el gRPC con Authorino.
  oc delete pod -n openshift-ingress \
    -l gateway.networking.k8s.io/gateway-name=maas-default-gateway --ignore-not-found
  oc rollout status -n openshift-ingress deploy/maas-default-gateway-openshift-default --timeout=180s
}

if oc get authorino authorino -n kuadrant-system >/dev/null 2>&1; then
  apply_authorino_fixes
else
  echo "WARN: authorino/authorino no existe en kuadrant-system; sin auto-fix"
fi

echo "=== Smoke test: POST https://maas.${CLUSTER_DOMAIN}/maas-api/v1/api-keys ==="
RESP=$(maas_api_check || true)
if echo "$RESP" | jq -e . >/dev/null 2>&1; then
  echo "OK: maas-api responde JSON (Authorino gRPC alineado)"
else
  echo "WARN: respuesta no JSON: ${RESP:0:120}"
  echo "Reintento: re-aplicando fixes de Authorino..."
  apply_authorino_fixes
  sleep 10
  RESP=$(maas_api_check || true)
  if echo "$RESP" | jq -e . >/dev/null 2>&1; then
    echo "OK: maas-api responde JSON tras re-aplicar fixes"
  else
    echo "ERROR: maas-api sigue devolviendo no-JSON:"
    echo "${RESP:0:200}"
    exit 1
  fi
fi

# --- Verificacion ---------------------------------------------------------------
echo "=== Verificacion ==="
printf '%-30s %s\n' "DSC" "$DSC"
oc get "$DSC"
printf '%-30s %s\n' "MaaS API" "https://maas.${CLUSTER_DOMAIN}"
oc get pods -n redhat-ai-gateway-infra
oc get pods -n redhat-ods-applications | grep -i maas || \
  echo "(aun no hay pods maas en redhat-ods-applications)"
oc get aitenant -A
oc get maastenantconfig -A
echo "Listo: maas-api / maas-controller en Running y /maas-api responde JSON."
