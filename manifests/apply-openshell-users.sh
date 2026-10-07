#!/usr/bin/env bash
# Provisiona OpenShell multi-usuario (modulo 23.1): SCC + ClusterRole del
# gateway (cluster-scoped, UNA VEZ) y por usuario: namespace dedicado
# openshell-<user> + rol edit + RBAC (SCC use, node-reader, CRUD Sandboxes).
# El DESPLIEGUE del gateway lo hace cada usuario con
# manifests/openshell-users/apply-my-openshell.sh (self-service, sin ser
# cluster-admin); PREDEPLOY=1 lo hace aqui como cluster-admin.
#
# Uso desde la raiz del repo (oc como cluster-admin):
#   bash manifests/apply-openshell-users.sh
#   USERS="jero rodri" bash manifests/apply-openshell-users.sh
#   PREDEPLOY=1 bash manifests/apply-openshell-users.sh   # despliega por ellos
set -euo pipefail
NS_PREFIX="${NS_PREFIX:-openshell}"
USERS="${USERS:-jero rodri pablo}"
PREDEPLOY="${PREDEPLOY:-0}"

oc whoami >/dev/null 2>&1 || { echo "ERROR: oc no logueado"; exit 1; }

echo "=== 1. SCC openshell-gateway + ClusterRole scc-use (una vez) ==="
oc apply -f manifests/openshell-users/openshell-gateway-scc.yaml

for U in $USERS; do
  NS="${NS_PREFIX}-${U}"
  echo "=== 2. ${NS}: namespace + RBAC de ${U} ==="
  oc get ns "$NS" >/dev/null 2>&1 || oc create namespace "$NS"
  oc adm policy add-role-to-user edit "$U" -n "$NS"
  tmp=$(mktemp)
  sed -e "s|__USER__|${U}|g" -e "s|__NS__|${NS}|g" \
    manifests/openshell-users/openshell-users-rbac-template.yaml > "$tmp"
  oc apply -f "$tmp"
  rm -f "$tmp"
  echo "    OK: ${U} tiene edit en ${NS}, SCC use y CRUD Sandboxes"
done

echo
echo "=== Siguientes pasos ==="
echo "  Cada usuario despliega SU OpenShell en SU namespace (self-service):"
echo "    NS=${NS_PREFIX}-<user> bash manifests/openshell-users/apply-my-openshell.sh"
if [[ "$PREDEPLOY" == "1" ]]; then
  for U in $USERS; do
    echo "=== PREDEPLOY: ${NS_PREFIX}-${U} ==="
    NS="${NS_PREFIX}-${U}" bash manifests/openshell-users/apply-my-openshell.sh
  done
fi
