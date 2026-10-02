#!/usr/bin/env bash
# Build the opencode agent image and deploy the headless HTTP server (opencode serve).
#
# Default: OpenShift internal registry (no quay credentials) + kubeconf-tmm in user-cestay.
# Optional quay.io:
#   QUAY_IMAGE=quay.io/<user>/opencode-agent:latest bash manifests/apply-opencode-agent.sh
#   (build+push first)
#
# Optional LLM keys for the agent (stored in opencode-auth secret):
#   API_KEY=sk-... PROVIDER=anthropic bash manifests/apply-opencode-agent.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export KUBECONFIG="${KUBECONFIG:-$ROOT/kubeconf-tmm}"
NS="${NS:-user-cestay}"
APP=opencode-agent
CTX="manifests/agents/opencode"
QUAY_IMAGE="${QUAY_IMAGE:-}"

oc get ns "$NS" >/dev/null

if [[ -n "$QUAY_IMAGE" ]]; then
  IMAGE="$QUAY_IMAGE"
  echo "Using pre-pushed image $IMAGE"
else
  echo "=== BuildConfig in cluster registry ==="
  oc -n "$NS" new-build --binary --name="$APP" --strategy=docker \
    --to="${APP}:latest" 2>/dev/null || true
  oc -n "$NS" start-build "$APP" --from-dir="$CTX" --follow --wait
  IMAGE="image-registry.openshift-image-registry.svc:5000/${NS}/${APP}:latest"
fi

echo "=== Auth secret (optional basic auth + optional LLM keys) ==="
# Basic auth is opt-in (AUTH_PASSWORD) because kubelet HTTP probes cannot send credentials.
if [[ -n "${AUTH_PASSWORD:-}" ]]; then
  oc -n "$NS" create secret generic opencode-auth \
    --from-literal=OPENCODE_SERVER_USERNAME="opencode" \
    --from-literal=OPENCODE_SERVER_PASSWORD="$AUTH_PASSWORD" \
    --dry-run=client -o yaml | oc apply -f -
fi
if [[ -n "${API_KEY:-}" ]]; then
  PROVIDER_KEY="OPENAI_API_KEY"
  [[ "${PROVIDER:-openai}" == "anthropic" ]] && PROVIDER_KEY="ANTHROPIC_API_KEY"
  oc -n "$NS" create secret generic opencode-auth \
    --from-literal="$PROVIDER_KEY"="$API_KEY" \
    --dry-run=client -o yaml | oc apply -f -
fi

echo "=== Deploy ==="
# Replace default image placeholder with the built/pushed image
tmp=$(mktemp)
sed "s|image: image-registry.openshift-image-registry.svc:5000/USER-NS/opencode-agent:latest|image: ${IMAGE}|" \
  manifests/agents/opencode-deploy.yaml > "$tmp"
oc apply -n "$NS" -f "$tmp"
rm -f "$tmp"

oc rollout status deploy/"$APP" -n "$NS" --timeout=300s || true
oc get deploy,svc,route -n "$NS" "$APP"
echo
echo "Endpoint: https://$(oc -n "$NS" get route "$APP" -o jsonpath='{.spec.host}')/doc"
