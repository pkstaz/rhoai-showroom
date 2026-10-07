#!/usr/bin/env bash
# Despliega TU OpenShell en TU namespace (modulo 23.1, self-service): bundle
# del chart oficial (gateway + policies + workspace resources) con Route
# publica passthrough TLS. Los permisos (SCC + node-reader) los provisiona
# manifests/apply-openshell-users.sh como cluster-admin; este script lo ejecuta
# el USUARIO (oc con edit en $NS, Helm 3) sin ser cluster-admin: filtra los
# recursos cluster-scoped del render porque no puede crearlos.
#
# Uso desde la raiz del repo:
#   NS=openshell-jero bash manifests/openshell-users/apply-my-openshell.sh
#   HOST=mi-shell.apps.example.com NS=openshell-jero bash ...   # host de la Route
#   MODE=delete NS=openshell-jero bash ...                      # borrar mi OpenShell
#
# Tras el deploy: Route publica en $HOST (el CLI remoto conecta con
# `openshell gateway add https://$HOST --name k8s` + bundle mTLS del secret
# openshell-client-tls) y el provider profile MaaS se importa con el CLI
# (ver modulo 23.1 en la guia).
set -euo pipefail
NS="${NS:-}"
HOST="${HOST:-}"
VERSION="${VERSION:-0.1.2}"
MODE="${MODE:-deploy}"

[[ -n "$NS" ]] || { echo "ERROR: export NS=<tu-namespace>"; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "ERROR: Helm 3 no instalado (modulo 0.1)"; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "ERROR: oc no logueado"; exit 1; }
oc -n "$NS" auth can-i create statefulsets >/dev/null 2>&1 \
  || { echo "ERROR: sin permisos de edit en ${NS} (pide el provisioning a un admin: manifests/apply-openshell-users.sh)"; exit 1; }

if [[ "$MODE" == "delete" ]]; then
  echo "=== Borrando mi OpenShell de ${NS} ==="
  helm template openshell oci://ghcr.io/nvidia/openshell/helm-chart \
    --version "${VERSION}" --namespace "${NS}" \
    --set agentSandbox.preflight.enabled=false \
    | awk '
      function flush() {
        if (buf != "" && !skip) {
          if (out != "") out = out "---\n"
          out = out buf
        }
        buf=""; skip=0
      }
      { if ($0=="---") { flush(); next } buf = buf $0 "\n" }
      /^kind: (ClusterRole|ClusterRoleBinding)$/ { skip=1 }
      END { flush(); printf "%s", out }
    ' | oc delete -f - --ignore-not-found=true -n "${NS}"
  echo "OK: OpenShell borrado de ${NS}"
  exit 0
fi

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
HOST="${HOST:-openshell-${NS}.${CLUSTER_DOMAIN}}"

echo "=== Bundle OpenShell ${VERSION} en ${NS} (Route publica: ${HOST}) ==="
# El certgen solo genera la PKI si los secrets no existen; con estado parcial
# falla. Borra el job y los 3 secrets TLS/JWT para regenerarlos con las SANs
# actuales (server-tls firma el client-tls; van juntos).
oc -n "$NS" delete job/openshell-certgen secret/openshell-server-tls secret/openshell-client-tls secret/openshell-jwt-keys --ignore-not-found=true 2>/dev/null || true
# Route con TLS passthrough (el gateway sirve su propio TLS con mTLS) y SAN
# del host en el cert (pkiInitJob.serverDnsNames). allowUnauthenticatedUsers
# solo para el lab; en Prd: OIDC o access proxy.
helm template openshell oci://ghcr.io/nvidia/openshell/helm-chart \
  --version "${VERSION}" \
  --namespace "${NS}" \
  --set agentSandbox.preflight.enabled=false \
  --set pkiInitJob.serverDnsNames={${HOST}} \
  --set openshiftRoute.enabled=true \
  --set openshiftRoute.host=${HOST} \
  --set server.auth.allowUnauthenticatedUsers=true \
  | awk '
    function flush() {
      if (buf != "" && !skip) {
        if (out != "") out = out "---\n"
        out = out buf
      }
      buf=""; skip=0
    }
    { if ($0=="---") { flush(); next } buf = buf $0 "\n" }
    /^kind: (ClusterRole|ClusterRoleBinding)$/ { skip=1 }
      END { flush(); printf "%s", out }
    ' | oc apply -f - -n "${NS}"

echo "=== Wait certgen + gateway ==="
oc -n "$NS" wait --for=condition=complete job/openshell-certgen --timeout=120s 2>/dev/null || \
  oc -n "$NS" get jobs,pods
# El gateway carga el cert al arrancar: restart para que coja el secret nuevo.
oc -n "$NS" rollout restart statefulset/openshell
oc -n "$NS" rollout status statefulset/openshell --timeout=300s

echo
echo "=== OK: tu OpenShell esta listo ==="
echo "  Route publica: https://${HOST}"
echo "  Siguientes pasos:"
echo "    1. Bundle mTLS: kubectl -n ${NS} get secret openshell-client-tls -o jsonpath='{.data.ca\\.crt}' | base64 -d > ~/.config/openshell/gateways/${NS}/mtls/ca.crt   # y tls.crt / tls.key"
echo "    2. openshell gateway add https://${HOST} --name ${NS} && openshell status"
echo "    3. Importa el provider MaaS: manifests/openshell/maas-provider-profile.yaml (modulo 23.1)"
