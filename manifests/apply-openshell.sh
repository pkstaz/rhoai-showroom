#!/usr/bin/env bash
# Despliega NVIDIA OpenShell (runtime seguro para agentes AI) en el cluster:
# CRDs + controller de Agent Sandbox (kubernetes-sigs) + gateway via Helm chart
# oficial (oci://ghcr.io/nvidia/openshell/helm-chart).
#
# Uso desde la raiz del repo (oc login ya hecho, Helm 3):
#   bash manifests/apply-openshell.sh
#   VERSION=0.1.0 bash manifests/apply-openshell.sh   # version del chart
#
# Requisitos:
#   - K8s 1.29+ (OpenShift 4.20+ OK) y Helm 3
#   - CNI que enforcee NetworkPolicy: OpenShift (OVN-Kubernetes) lo cumple
#   - Salida a ghcr.io y registry.k8s.io
#
# Tras el install, la pagina del modulo 23 cubre el CLI (openshell), el
# port-forward + TLS bundle y los providers (OpenRouter quickstart + MaaS del
# cluster).
#
# Idempotente: se puede re-ejecutar (helm upgrade --install).
set -euo pipefail
NS="${NS:-openshell}"
VERSION="${VERSION:-0.1.2}"

echo "=== 1/4 Agent Sandbox: CRDs + controller (kubernetes-sigs) ==="
oc apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/latest/download/sandbox.yaml
oc -n agent-sandbox-system rollout status deploy/agent-sandbox-controller --timeout=180s

echo "=== 2/4 Namespace ${NS} + SCC anyuid (el gateway corre como UID 1000) ==="
oc get ns "$NS" >/dev/null 2>&1 || oc create namespace "$NS"
oc adm policy add-scc-to-user anyuid -z openshell -n "$NS"

echo "=== 3/4 Gateway OpenShell via Helm (${VERSION}) ==="
# allowUnauthenticatedUsers solo para el lab (port-forward local); en Prd: OIDC
# o access proxy.
helm upgrade --install openshell \
  oci://ghcr.io/nvidia/openshell/helm-chart \
  --version "${VERSION}" \
  --namespace "${NS}" \
  --set server.auth.allowUnauthenticatedUsers=true

echo "=== 4/4 Ready ==="
oc -n "$NS" rollout status statefulset/openshell --timeout=300s

echo
echo "=== Siguientes pasos (modulo 23) ==="
echo "  1. CLI: curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh"
echo "  2. Port-forward + TLS bundle:"
echo "     kubectl -n ${NS} port-forward svc/openshell 8080:8080"
echo "     mkdir -p ~/.config/openshell/gateways/k8s/mtls"
echo "     kubectl -n ${NS} get secret openshell-client-tls -o jsonpath='{.data.ca\\.crt}'  | base64 -d > ~/.config/openshell/gateways/k8s/mtls/ca.crt"
echo "     kubectl -n ${NS} get secret openshell-client-tls -o jsonpath='{.data.tls\\.crt}' | base64 -d > ~/.config/openshell/gateways/k8s/mtls/tls.crt"
echo "     kubectl -n ${NS} get secret openshell-client-tls -o jsonpath='{.data.tls\\.key}' | base64 -d > ~/.config/openshell/gateways/k8s/mtls/tls.key"
echo "  3. openshell gateway add https://127.0.0.1:8080 --local --name k8s && openshell status"
