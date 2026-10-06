#!/usr/bin/env bash
# Despliega un agente OpenCode (opencode serve) por usuario del workshop en el
# proyecto opencode-users: config con provider MaaS del propio cluster (API key
# via secret opencode-maas-key-<user>), Route por usuario y RoleBinding edit
# para que cada usuario gestione su agente desde la console.
#
# Uso desde la raiz del repo (oc login ya hecho):
#   bash manifests/apply-opencode-users.sh
#   USERS="jero rodri" bash manifests/apply-opencode-users.sh   # lista custom
#
# API key MaaS por usuario (el usuario la crea en el Playground o via maas-api):
#   oc -n opencode-users create secret generic opencode-maas-key-<user> \
#     --from-literal=MAAS_API_KEY=sk-oai-...
#   oc -n opencode-users rollout restart deploy/opencode-<user>
#
# Idempotente: se puede re-ejecutar.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
NS="${NS:-opencode-users}"
USERS="${USERS:-jero rodri pablo}"
APP=opencode-agent
IMAGE="image-registry.openshift-image-registry.svc:5000/${NS}/${APP}:latest"
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')

oc get ns "$NS" >/dev/null

echo "=== ServiceAccount compartido (${NS}/opencode-agent) ==="
oc -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: opencode-agent
  namespace: ${NS}
EOF

echo "=== Imagen en el registry interno (build si no existe) ==="
if ! oc -n "$NS" get imagestream "${APP}" >/dev/null 2>&1; then
  oc -n "$NS" new-build --binary --name="${APP}" --strategy=docker --to="${APP}:latest" 2>/dev/null || true
  oc -n "$NS" start-build "${APP}" --from-dir="manifests/agents/opencode" --follow --wait
else
  echo "ImageStream ${APP} ya existe: usando ${IMAGE}"
fi

for U in $USERS; do
  echo "=== Agente opencode-${U} ==="
  tmp=$(mktemp)
  sed -e "s|__USER__|${U}|g" -e "s|__IMAGE__|${IMAGE}|g" -e "s|__CLUSTER_DOMAIN__|${CLUSTER_DOMAIN}|g" \
    manifests/agents/opencode-users-template.yaml > "$tmp"
  oc -n "$NS" apply -f "$tmp"
  rm -f "$tmp"
  oc -n "$NS" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: opencode-${U}-edit
  namespace: ${NS}
subjects:
  - kind: User
    name: ${U}
roleRef:
  kind: ClusterRole
  name: edit
EOF
  oc -n "$NS" rollout status "deploy/opencode-${U}" --timeout=300s || true
  ROUTE=$(oc -n "$NS" get route "opencode-${U}" -o jsonpath='{.spec.host}')
  echo "  UI:  https://${ROUTE}"
  echo "  API: https://${ROUTE}/doc"
done

echo
echo "=== API key MaaS por usuario (la crean ellos) ==="
echo "Cada usuario crea su key en el Playground o via maas-api y la inyecta en su agente:"
echo "  oc -n ${NS} create secret generic opencode-maas-key-<user> --from-literal=MAAS_API_KEY=sk-oai-..."
echo "  oc -n ${NS} rollout restart deploy/opencode-<user>"
