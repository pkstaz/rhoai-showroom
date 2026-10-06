# Reference — deploy-on-openshift-pre-provisioned

Read this when executing Authorino uninstall, Kueue recovery, GPU Booking `--no-hooks`, Authorino gRPC TLS, gpt-oss serving, dual MaaS subscriptions, or playground OGX. This skill does **not** install Fake GPU or GPU Config Plugin.

## Uninstall standalone Authorino

Authorino must not remain as its own Operator. Connectivity Link (Kuadrant) will install it.

Standalone Authorino on this pre-set cluster is often **AllNamespaces**. OLM copies `authorino-operator.*` CSV into **every** namespace. Deleting only the Subscription in `openshift-operators` is not enough: copies recreate the operator.

```bash
oc get csv -A | grep -iE 'authorino|rhcl|connectivity'
oc get subscription -A | grep -iE 'authorino|rhcl|connectivity'
oc get authorino -A
oc get operators.operators.coreos.com | grep -i authorino || true
```

Delete Authorino CRs first (if any), then OLM objects whose **name is Authorino**, not `rhcl-operator`:

```bash
AUTHORINO_NS=$(oc get subscription -A --no-headers | awk 'tolower($2) ~ /authorino/ {print $1; exit}')
AUTHORINO_SUB=$(oc get subscription -A --no-headers | awk 'tolower($2) ~ /authorino/ {print $2; exit}')

if [ -n "$AUTHORINO_SUB" ]; then
  oc delete authorino --all -A --ignore-not-found
  oc delete subscription "$AUTHORINO_SUB" -n "$AUTHORINO_NS"
  oc delete operators.operators.coreos.com "authorino-operator.${AUTHORINO_NS}" --ignore-not-found
fi

# Wipe CSV copies in every namespace (AllNamespaces leak)
oc get csv -A --no-headers | awk 'tolower($2) ~ /authorino/ {print $1, $2}' \
  | while read -r ns name; do
      oc delete csv "$name" -n "$ns" --ignore-not-found --wait=false
    done

oc get csv -A | grep -i authorino || echo "Authorino operator gone"
```

Do not delete CRDs unless Connectivity Link CSV then fails on CRD ownership. Prefer letting rhcl reconcile Authorino.

Then:

```bash
oc apply -f manifests/operators/connectivity-link/
```

Wait until CSV matching `connectivity` / `rhcl` is `Succeeded`. Authorino CSV returning **via Kuadrant** afterwards is expected.

## Kueue (stable-v1.4 / 1.4.2, AllNamespaces)

`manifests/operators/kueue/subscription.yaml` is already: channel `stable-v1.4`, OperatorGroup `spec: {}`.

- Channel `stable-v1.0` **does not exist** in this catalog. Confirm with:
  ```bash
  oc get packagemanifest kueue-operator -n openshift-marketplace \
    -o jsonpath='default={.status.defaultChannel} channels={.status.channels[*].name}{"\n"}'
  ```
- OwnNamespace / `targetNamespaces: [openshift-kueue-operator]` is **unsupported**. CSV never Succeeds.
- After changing OG or channel, Subscription can stick in `UpgradePending` with **no InstallPlan**. Recover:
  ```bash
  oc delete subscription kueue-operator -n openshift-kueue-operator
  oc apply -f manifests/operators/kueue/
  oc wait csv/kueue-operator.v1.4.2 -n openshift-kueue-operator --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
  ```
- AllNamespaces copies the Kueue CSV into many namespaces. Success criterion is `kueue-operator.v1.4.2` **Succeeded**, not “only one CSV row”.

## Skip Fake GPU and GPU Config Plugin

Do not install Fake GPU Operator or GPU Configuration Plugin on this pre-set AWS cluster. The compact L4 already provides one real GPU; DCGM / NVIDIA GPU Operator collection stays standard.

If a previous skill run left Fake GPU / GPU Config:

- Uninstall Helm `gpu-config-plugin` with `--no-hooks`, drop ConsolePlugin `gpu-config-plugin` from `consoles.operator.openshift.io/cluster`, delete ns `gpu-config-plugin`.
- Delete Fake workloads in ns `gpu-operator` (not `nvidia-gpu-operator`) and ClusterRoles `fake-*` / `mig-faker`. **Never** delete ClusterRole `nvidia-device-plugin` (NVIDIA-owned).
- Unlabel the CPU worker (`run.ai/fake.gpu`, `run.ai/simulated-gpu-node-pool`, fake `nvidia.com/gpu.product` / `gpu.count` / MIG labels).
- Delete hardwareprofiles `fake-h200`, `fake-h200-mig`, and GPU-Config-managed `unreserved-*`.
- Reinstall GPU Booking with discovery **on** (below). Do not run `manifests/apply-gpu-booking-hybrid.sh`.

## GPU Booking (`--no-hooks`, auto-discovery)

Discovery is `GET /api/v1/nodes?labelSelector=nvidia.com/gpu.present=true`. With Fake GPU gone, that is the compact L4 only.

```bash
git clone --depth 1 https://github.com/rhai-code/gpu-booking-app-plugin.git /tmp/gpu-booking-app-plugin
helm upgrade -i gpu-booking-plugin /tmp/gpu-booking-app-plugin/chart/ \
  -n gpu-booking-app-plugin --create-namespace --no-hooks
```

`--no-hooks` is mandatory (`ose-cli:latest` ImagePullBackOff). If a previous Helm release hung, `helm uninstall gpu-booking-plugin -n gpu-booking-app-plugin --no-hooks` then re-install. Enable ConsolePlugin `gpu-booking-plugin` if it is not already in `.spec.plugins`.

Logs should show `gpu discovery: initial config applied` with `resources: 1`. Do not set `gpuDiscovery.enabled=false` or mount a static `gpu-config.json`.

## Authorino gRPC TLS (HTTP 500 on `/maas-api/v1/api-keys`)

Two different Authorino problems:

| Symptom | Cause | Fix |
|---|---|---|
| `/v1/models` or chat `AUTH_FAILURE` / “Exception thrown while generating token” | Authorino cannot trust `maas-api` TLS | `bash manifests/apply-maas.sh` (Authorino auto-fix) |
| `POST /maas-api/v1/api-keys` **HTTP 500**; Envoy `kuadrant-auth-service` gRPC not OK | EnvoyFilter `openshift-ai-inference-authn-ssl` makes wasm talk **TLS** to Authorino `:50051`; Authorino listener is **plaintext** | `bash manifests/apply-maas.sh` (Authorino auto-fix) |

Do **not** try to strip TLS with DestinationRule `tls.mode=DISABLE` or EnvoyFilter MERGE → `raw_buffer`. Those lose against `openshift-ai-inference-authn-ssl`. Enable Authorino listener TLS with an OpenShift serving cert, then **delete the MaaS gateway pod** so Envoy reconnects.

Expect HTTP **201** on a new API key. Never print the `key` field in user-facing chat.

## gpt-oss-20b (llm-d, GPU, MaaS, tool calling)

File already exists: `manifests/llminferenceservice-gpt-oss-20b.yaml`.

Use CUDA vLLM (not the CPU image): `registry.redhat.io/rhaii-early-access/vllm-cuda-rhel9:3.5.0-ea.2`.

Pin to the **real** NVIDIA node. Committed selector is `nvidia.com/gpu.product: NVIDIA-L4` (this AWS lab). Confirm:

```bash
oc get nodes -o json | jq -r '.items[] | [
  .metadata.name,
  (.status.allocatable["nvidia.com/gpu"] // "0"),
  (.metadata.labels["nvidia.com/gpu.product"] // "-"),
  (.metadata.labels["node-role.kubernetes.io/master"] // .metadata.labels["node-role.kubernetes.io/control-plane"] // "")
] | @tsv'
```

If product is not `NVIDIA-L4`, patch `spec.template.nodeSelector` (node name or `feature.node.kubernetes.io/pci-10de.present=true`). Compact GPU masters are valid targets.

Apply **in parallel** with Qwen:

```bash
oc apply -f manifests/llminferenceservice-qwen3-06b.yaml
oc apply -f manifests/llminferenceservice-gpt-oss-20b.yaml
oc wait --for=condition=Ready llminferenceservice/qwen3-06b -n llm --timeout=900s
oc wait --for=condition=Ready llminferenceservice/gpt-oss-20b -n llm --timeout=1800s
```

## MaaS subscriptions for both models

```bash
oc apply -f manifests/maas-subscription.yaml
oc apply -f manifests/maas-subscription-gpt-oss-20b.yaml
```

API keys: subscription names `qwen-authenticated` and `gpt-oss-20b-authenticated`.

## Curl smoke

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
MAAS_URL="maas.${CLUSTER_DOMAIN}"

# Capture keys; do not echo them to the user
Qwen_KEY=$(curl -sk -X POST "https://${MAAS_URL}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"workshop-qwen","subscription":"qwen-authenticated","expiresIn":"8h"}' | jq -r '.key')

GPT_KEY=$(curl -sk -X POST "https://${MAAS_URL}/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $(oc whoami -t)" \
  -H "Content-Type: application/json" \
  -d '{"name":"workshop-gpt","subscription":"gpt-oss-20b-authenticated","expiresIn":"8h"}' | jq -r '.key')

curl -sk "https://${MAAS_URL}/v1/models" -H "Authorization: Bearer ${Qwen_KEY}" | jq '.data[].id'
curl -sk "https://${MAAS_URL}/v1/models" -H "Authorization: Bearer ${GPT_KEY}" | jq '.data[].id'

curl -sk "https://${MAAS_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${Qwen_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"publishers/llm/models/qwen3-06b","messages":[{"role":"user","content":"Say hello in one sentence. /no_think"}],"max_tokens":64}' \
  | jq -r '.choices[0].message.content'

# gpt-oss spends tokens on reasoning; 64 often yields content=None with finish_reason=length
curl -sk "https://${MAAS_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${GPT_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"publishers/llm/models/gpt-oss-20b","messages":[{"role":"user","content":"Say hello in one sentence."}],"max_tokens":256}' \
  | jq -r '.choices[0].message.content'
```

If `/v1/models` returns AUTH_FAILURE or key creation returns HTTP 500, re-run `bash manifests/apply-maas.sh` (Authorino auto-fix, idempotent).

## Playground OGXServer

`bash manifests/fix-playground-maas.sh` needs `ogxservers.ogx.io/lsd-genai-playground` in `llm`. OGX does **not** create that CR until a user opens **Gen AI Studio → Playground** (project `llm`) once.

If `oc get ogxserver -A` is empty: the secret `playground-maas-api-key` may already exist; stop, tell the user to open Playground, then re-run the script. Do not block the rest of the lab (Observability) on this.

If the dashboard regenerates the OGXServer, `VLLM_API_TOKEN=fake` / `VLLM_MAX_TOKENS=4096` come back — re-run the script.

## GPU utilization dashboard (real L4)

RHOAI Observe cluster/model GPU panels query **cluster Prometheus** (`cluster-prometheus-datasource`) for `accelerator_gpu_utilization`. That name is the NVIDIA translation of `DCGM_FI_DEV_GPU_UTIL`; this GPU Operator build only ships alerts, so the series is missing until:

```bash
bash manifests/fix-maas-gpu-utilization.sh
```

The script applies:

- `monitoring.coreos.com` `PrometheusRule` `nvidia-dcgm-accelerator` in `nvidia-gpu-operator` (namespace already has `openshift.io/cluster-monitoring=true`) so cluster Thanos serves `accelerator_gpu_utilization`.
- RHOBS `ServiceMonitor` + `PrometheusRule` in `redhat-ods-monitoring` for the LLM-d utilization dashboard (`data-science-prometheus-datasource`), joined with vLLM `model_name`.

Do not divide DCGM by 100; Perses unit is percent 0–100. Qwen is CPU → no DCGM join → No data for that model is expected. Filter to gpt-oss or All. Idle L4 is **0%**, not No data; generate chat completions to see a spike.
