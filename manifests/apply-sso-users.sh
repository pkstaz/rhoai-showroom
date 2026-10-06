#!/usr/bin/env bash
# Crea usuarios del workshop en el SSO (RHBK Keycloak, realm sso) con perfil
# completo (sin VERIFY_PROFILE en el primer login) y password aleatoria.
# Los usuarios se mapean a OpenShift por preferred_username y acceden a MaaS
# via la subscripcion workshop-users (manifests/maas-subscription-workshop-users.yaml):
# cada usuario crea su API key en el Playground / maas-api.
#
# Uso desde la raiz del repo (oc login ya hecho):
#   bash manifests/apply-sso-users.sh
#   USERS="jero rodri" bash manifests/apply-sso-users.sh   # lista custom
#
# Idempotente: los usuarios existentes no se tocan (passwords no se resetean).
set -euo pipefail

USERS="${USERS:-jero rodri pablo}"
KC_HOSTNAME="${KC_HOSTNAME:-$(oc get keycloak keycloak -n keycloak -o jsonpath='{.spec.hostname}')}"
KC="https://${KC_HOSTNAME}"

ADMIN_USER=$(oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.username}' | base64 -d)
ADMIN_PASS=$(oc get secret keycloak-initial-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d)
TOKEN=$(curl -sk -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
  -d "grant_type=password" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

for U in $USERS; do
  PASS=$(python3 -c "import secrets,string; print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(12)))")
  EXISTS=$(curl -sk -H "Authorization: Bearer $TOKEN" "$KC/admin/realms/sso/users?username=$U&exact=true" \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
  if [ "$EXISTS" != "0" ]; then
    echo "$U: ya existe en el realm (sin cambios)"
    continue
  fi
  # Perfil completo (firstName/lastName/email + emailVerified): sin VERIFY_PROFILE.
  curl -sk -o /dev/null -X POST "$KC/admin/realms/sso/users" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"username\":\"$U\",\"email\":\"$U@lab.local\",\"emailVerified\":true,\"enabled\":true,\"firstName\":\"$U\",\"lastName\":\"lab\"}"
  KUID=$(curl -sk -H "Authorization: Bearer $TOKEN" "$KC/admin/realms/sso/users?username=$U&exact=true" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
  curl -sk -o /dev/null -X PUT "$KC/admin/realms/sso/users/$KUID/reset-password" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"type\":\"password\",\"value\":\"$PASS\",\"temporary\":false}"
  echo "$U: creado | password: $PASS"
done

echo
echo "Usuarios en realm sso:"
curl -sk -H "Authorization: Bearer $TOKEN" "$KC/admin/realms/sso/users" \
  | python3 -c "import sys,json; print(' ', ', '.join(u['username'] for u in json.load(sys.stdin)))"
echo "Acceso MaaS: subscripcion workshop-users (3 modelos). Cada usuario crea su API key en el Playground o:"
echo "  curl -sk -X POST https://maas.\${CLUSTER_DOMAIN}/maas-api/v1/api-keys -H \"Authorization: Bearer \$(oc whoami -t)\" -H 'Content-Type: application/json' -d '{\"name\":\"mi-key\",\"expiresIn\":\"24h\"}'"
