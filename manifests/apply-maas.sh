#!/usr/bin/env bash
# Habilitar MaaS (modulo 4) end-to-end:
#   operador Connectivity Link (si falta) -> GatewayClass + Istio -> Kuadrant
#   -> Postgres + maas-db-config -> Gateway maas-default-gateway
#   -> modelsAsAService: Managed en el DSC.
#
# Uso desde otro proyecto (con oc login ya hecho en el cluster):
#   git clone git@github.com:pkstaz/rhoai-showroom.git
#   bash rhoai-showroom/manifests/apply-maas.sh
#
# Flags:
#   --skip-operator   El Operator de Connectivity Link ya esta instalado (modulo 2)
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

# --- 0. Operator de Connectivity Link (pre-requisito, modulo 2) -------------
if [[ $SKIP_OPERATOR -eq 0 ]]; then
  CSV=$(oc get csv -n openshift-operators --no-headers 2>/dev/null \
    | grep -i connectivity | awk '{print $1}' | head -1 || true)
  if [[ -z "$CSV" ]]; then
    echo "=== Operator de Connectivity Link ==="
    oc apply -f manifests/operators/connectivity-link/subscription.yaml
  else
    echo "=== Operator de Connectivity Link ($CSV ya instalado) ==="
  fi
  for i in $(seq 1 60); do
    CSV=$(oc get csv -n openshift-operators --no-headers 2>/dev/null \
      | grep -i connectivity | awk '{print $1}' | head -1 || true)
    [[ -z "$CSV" ]] && { echo "esperando CSV del operador (try $i)"; sleep 10; continue; }
    PHASE=$(oc get csv "$CSV" -n openshift-operators -o jsonpath='{.status.phase}')
    [[ "$PHASE" == "Succeeded" ]] && { echo "CSV $CSV: Succeeded"; break; }
    echo "CSV $CSV: $PHASE (try $i)"
    sleep 10
  done
  [[ -n "$CSV" && "$PHASE" == "Succeeded" ]] || { echo "ERROR: el operador no quedo Succeeded"; exit 1; }
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

# --- Verificacion ---------------------------------------------------------------
echo "=== Verificacion ==="
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
printf '%-30s %s\n' "DSC" "$DSC"
oc get "$DSC"
printf '%-30s %s\n' "MaaS API" "https://maas.${CLUSTER_DOMAIN}"
oc get pods -n redhat-ai-gateway-infra
oc get pods -n redhat-ods-applications | grep -i maas || \
  echo "(aun no hay pods maas en redhat-ods-applications)"
oc get aitenant -A
oc get maastenantconfig -A
echo "Listo: maas-api / maas-controller en Running."
