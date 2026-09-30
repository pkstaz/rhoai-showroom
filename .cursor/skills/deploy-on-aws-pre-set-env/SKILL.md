---
name: deploy-on-aws-pre-set-env
description: Deploys the RHOAI MaaS lab onto an AWS OpenShift cluster that is already pre-provisioned (RHOAI 3.5.1, cert-manager, Pipelines, NFD, NVIDIA GPU Operator, admin user). Use when the user says deploy-on-aws-pre-set-env, asks to deploy the workshop on a pre-set AWS cluster, or to continue from an existing DataScienceCluster/default-dsc.
---

# Deploy on AWS pre-set env

Run every `oc apply` / script from the **repo root**. Do not install operators or users already marked OK. Stop after Observability; do not continue to EvalHub/FinOps/Guardrails.

`oc` in this Cursor sandbox needs `required_permissions: ["all"]`. If a command is blocked, retry with `all`. Never invent cluster state.

Copy this checklist and track progress:

```
Task Progress:
- [ ] 0. Validate oc login
- [ ] 1. Web Terminal (no admin user)
- [ ] 2. Scale CPU MachineSets zones a/b/c to 1
- [ ] 3. Uninstall standalone Authorino
- [ ] 4. Operators: Connectivity Link, Leader Worker Set, Kueue
- [ ] 5. User-workload monitoring
- [ ] 6. Patch DataScienceCluster (OGX)
- [ ] 7. ODHDashboardConfig
- [ ] 8. Hardware profile CPU (+ nvidia-gpu)
- [ ] 9. MaaS: GatewayClass, Kuadrant, Postgres, Gateway, modelsAsAService
- [ ] 10. Skip Fake GPU and GPU Config Plugin
- [ ] 11. GPU Booking Plugin
- [ ] 12. Delete my-first-model
- [ ] 13. Model Catalog Qwen3-0.6B
- [ ] 14. Parallel: Qwen3-0.6B (CPU) + gpt-oss-20b (GPU, tool calling)
- [ ] 15. Subscriptions for both models
- [ ] 16. Validate curl + playground
- [ ] 17. Observability
```

Gotchas (Authorino CSV copies, Kueue AllNamespaces, skip Fake GPU / GPU Config, GPU Booking `--no-hooks`, Authorino gRPC TLS, GPU utilization recording rule, playground OGXServer): [reference.md](reference.md).

## Cluster facts (do not contradict)

- AWS OpenShift. **One real GPU** — often a **compact control-plane** (`g6.*`, product e.g. `NVIDIA-L4`), not a GPU worker MachineSet.
- CPU MachineSets exist in **several AZs**. Scale **zones a, b, and c to 1 replica**. Leave other CPU AZs (d/e/f) as they are. Do not scale GPU MachineSets.
- Identify GPU vs CPU by `status.allocatable["nvidia.com/gpu"]` and `nvidia.com/gpu.product`, not by MachineSet name alone.
- Admin user **already exists**. Do **not** create htpasswd/`admin`.
- RHOAI `rhods-operator.3.5.1` **OK**. Do **not** install `manifests/rhoai-operator.yaml`.
- DSC `default-dsc` exists (`Ready=True`). OGXReady starts **PENDIENTE**. Pods `redhat-ods-applications` already Running.
- Operators **OK, skip**: cert-manager, OpenShift Pipelines, Node Feature Discovery, NVIDIA GPU Operator.
- **Do not** install Fake GPU Operator or GPU Configuration Plugin. Metrics stay on the real NVIDIA stack (DCGM). GPU Booking uses auto-discovery (`nvidia.com/gpu.present=true`) and sees only the L4.
- Operators **PENDIENTE, install**: Connectivity Link, Leader Worker Set, Kueue.
- **Kueue** is Red Hat build: channel `stable-v1.4`, CSV `kueue-operator.v1.4.2`. OperatorGroup **AllNamespaces** (`spec: {}`). OwnNamespace is unsupported.
- Standalone **Authorino operator is installed** (often AllNamespaces, CSV copied to every ns). Uninstall it **before** Connectivity Link (Authorino returns via Kuadrant).

## 0. Validate oc CLI is logged in

```bash
command -v oc >/dev/null
oc whoami && oc whoami --show-server && oc project -q
oc get nodes
```

If `oc whoami` / `oc get nodes` fail, **stop**. Ask the user to `oc login`. Do not invent kubeconfigs.

## 1. Web Terminal

Install only if CSV is missing. Do **not** create an admin user (skip htpasswd / `cluster-admin` / logout).

```bash
oc get csv -A | grep -iE 'webterminal|devworkspace' || true
```

If not `Succeeded`, apply a Subscription in `openshift-operators` (`name: web-terminal`, `source: redhat-operators`, `installPlanApproval: Automatic`) and wait for CSV `Succeeded` (DevWorkspace is a dependency).

```bash
oc get csv -A | grep -iE 'webterminal|devworkspace'
```

## 2. CPU MachineSets (zones a, b, c → 1 replica)

```bash
oc get machineset -n openshift-machine-api \
  -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.replicas,READY:.status.readyReplicas,AZ:.spec.template.spec.providerSpec.value.placement.availabilityZone,TYPE:.spec.template.spec.providerSpec.value.instanceType
```

Identify **CPU** MachineSets (not GPU instance types such as `g*`, `p*`, `Inf*`, `NC*`). Scale the ones whose AZ suffix is **a, b, and c** to 1:

```bash
oc scale machineset <name> -n openshift-machine-api --replicas=1
```

Wait until those 3 CPU machines / nodes are Ready. Extra CPU workers in other AZs may already exist — leave them.

## 3. Uninstall standalone Authorino

Connectivity Link owns Authorino. A preinstalled Authorino Operator conflicts.

```bash
oc get csv -A | grep -iE 'authorino|connectivity|rhcl'
oc get subscription -A | grep -iE 'authorino|rhcl|connectivity'
```

Delete **only** standalone Authorino (`authorino-operator`, CSV `authorino-operator.*`). Do **not** delete `rhcl-operator`.

AllNamespaces copies the CSV into **every** namespace. After deleting the Subscription, delete **all** Authorino CSV copies and the `operators.operators.coreos.com` CR, or OLM recreates it. Connectivity Link will reinstall Authorino later — that is expected.

Details: [reference.md](reference.md).

## 4. Pending operators

Skip cert-manager and Pipelines. Wait CSV `Succeeded` between each:

```bash
oc apply -f manifests/operators/connectivity-link/
# wait rhcl / connectivity CSV Succeeded
oc apply -f manifests/operators/leader-worker-set/
# wait lws CSV Succeeded
oc apply -f manifests/operators/kueue/
# wait kueue CSV Succeeded (kueue-operator.v1.4.2)
```

Confirm packagemanifest channel before applying if the catalog looks different: `oc get packagemanifest kueue-operator -n openshift-marketplace`. Expected default: `stable-v1.4`. Manifest already uses AllNamespaces `spec: {}`.

If the Subscription sits in `UpgradePending` with no InstallPlan after an OG/channel change: delete the Subscription and re-apply `manifests/operators/kueue/`.

Re-run the operator table from `content/modules/ROOT/pages/02-00-operators.adoc` until Connectivity Link, LWS, and Kueue are **OK**.

## 5. User-workload monitoring

```bash
oc apply -f manifests/cluster-monitoring-config.yaml
oc get pods -n openshift-user-workload-monitoring
```

Wait until those pods are Running.

## 6. DataScienceCluster (already deployed)

Do **not** recreate from scratch blindly. Apply `manifests/default-dsc.yaml` (idempotent) so **OGX** is `Managed` and other lab components match. Keep `aigateway.modelsAsAService` **Removed** until step 9.

```bash
oc apply -f manifests/default-dsc.yaml
oc wait --for=condition=Ready dsc/default-dsc --timeout=900s
```

Wait until `OGXReady=True`. Re-run the status table from `content/modules/ROOT/pages/03-02-dsc.adoc`.

## 7. ODHDashboardConfig

```bash
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type merge -p '{
  "spec": {
    "dashboardConfig": {
      "disableModelCatalog": false,
      "disableModelRegistry": false,
      "disableKueue": false,
      "modelAsService": true,
      "genAiStudio": true,
      "disableLMEval": false,
      "observabilityDashboard": true
    }
  }
}'
```

## 8. Hardware profiles

```bash
oc apply -f manifests/hardware-profile-cpu.yaml
oc apply -f manifests/hardware-profile-nvidia.yaml
oc get hardwareprofile -n redhat-ods-applications
```

`cpu-workshop` is required for Qwen. `nvidia-gpu` is required for gpt-oss-20b on the real GPU.

## 9. Enable MaaS

Order is mandatory:

1. GatewayClass, wait Istio:
   ```bash
   oc apply -f manifests/maas/gatewayclass.yaml
   oc wait --for=condition=Accepted gatewayclass/openshift-default --timeout=2m
   oc rollout status -n openshift-ingress deploy/istiod-openshift-gateway --timeout=5m
   ```
2. Kuadrant **only after** Istio is ready:
   ```bash
   oc create namespace kuadrant-system --dry-run=client -o yaml | oc apply -f -
   oc apply -f manifests/maas/kuadrant.yaml
   oc wait kuadrant/kuadrant -n kuadrant-system --for=condition=Ready --timeout=5m
   ```
   If Kuadrant says Gateway API provider is missing, restart the Kuadrant controller (see `content/modules/ROOT/pages/04-00-connectivity.adoc`).
3. Postgres:
   ```bash
   oc apply -f manifests/maas/maas-postgres.yaml
   oc wait -n redhat-ai-gateway-infra --for=condition=available deploy/maas-postgres --timeout=300s
   ```
4. Gateway:
   ```bash
   bash manifests/apply-maas-gateway.sh
   ```
5. Turn on MaaS:
   ```bash
   oc patch dsc default-dsc --type merge -p '{
     "spec": {
       "components": {
         "aigateway": {
           "managementState": "Managed",
           "modelsAsAService": { "managementState": "Managed" }
         }
       }
     }
   }'
   ```

Wait `maas-api` / `maas-controller` Running.

## 10. Skip Fake GPU and GPU Config Plugin

Do **not** install Fake GPU Operator, `manifests/hardware-profiles-fake.yaml`, or GPU Configuration Plugin. NFD + NVIDIA GPU Operator are already OK; leave them.

Fake GPU fights the real NVIDIA stack (ClusterRole `nvidia-device-plugin`, `nvidia.com/gpu.present=false`, GB300 profiles) and breaks standard DCGM collection. This skill uses the compact L4 only.

If a previous run left leftovers, remove **only** Fake / GPU Config (never `nvidia-gpu-operator` or ClusterRole `nvidia-device-plugin`): namespace `gpu-operator` (Fake), Helm release + ns `gpu-config-plugin`, ConsolePlugin `gpu-config-plugin`, hardwareprofiles `fake-h200*` / `unreserved-*`, ClusterRoles `fake-*` / `mig-faker` / `gpu-config-plugin-*`, and Fake labels on CPU workers (`run.ai/fake.gpu`, `run.ai/simulated-gpu-node-pool`, fake `nvidia.com/gpu.product`). Then reinstall GPU Booking with discovery on (step 11).

## 11. GPU Booking Plugin

Requires Kueue. Use **auto-discovery** (default): it lists nodes with `nvidia.com/gpu.present=true` — the real L4. Do **not** run `manifests/apply-gpu-booking-hybrid.sh` (that is for Fake GPU).

```bash
git clone --depth 1 https://github.com/rhai-code/gpu-booking-app-plugin.git /tmp/gpu-booking-app-plugin
helm upgrade -i gpu-booking-plugin /tmp/gpu-booking-app-plugin/chart/ \
  -n gpu-booking-app-plugin --create-namespace --no-hooks
```

`--no-hooks` is mandatory: the post-install Job uses `ose-cli:latest` and ImagePullBackOffs. Enable the ConsolePlugin if it is not already listed:

```bash
oc patch consoles.operator.openshift.io cluster --type=json \
  -p '[{"op":"add","path":"/spec/plugins/-","value":"gpu-booking-plugin"}]'
```

Skip the patch if `gpu-booking-plugin` is already in `.spec.plugins`. Verify one Full GPU card (L4).

## 12. Delete preinstalled Llama

Namespace `my-first-model` has a preinstalled model. Remove the model **and** the namespace:

```bash
oc delete llminferenceservice,inferenceservice,servingruntime,isvc --all -n my-first-model --ignore-not-found
oc delete project my-first-model --wait=true
```

If the namespace sticks in Terminating, remove remaining CRs/finalizers and wait.

## 13. Model Catalog — Qwen3-0.6B

```bash
oc apply -f manifests/model-catalog-qwen.yaml
oc delete pod -n rhoai-model-registries -l component=model-catalog --ignore-not-found
```

If `model-catalog-sources` already exists, **merge** the Qwen catalog entry instead of replacing unrelated catalogs.

## 14. Deploy both models in parallel

Create **both** `LLMInferenceService` + `MaaSModelRef` objects, then wait. Do not serialize apply.

- **Qwen3-0.6B**: llm-d, **CPU**, MaaS — `oc apply -f manifests/llminferenceservice-qwen3-06b.yaml`
- **gpt-oss-20b**: llm-d, **real GPU**, MaaS, tool calling — `oc apply -f manifests/llminferenceservice-gpt-oss-20b.yaml`

Constraints:

- Qwen stays on CPU image `registry.redhat.io/rhaii-early-access/vllm-cpu-rhel9:3.5.0-ea.2` (no `nvidia.com/gpu`).
- gpt-oss-20b must schedule on the **NVIDIA** node. Committed YAML pins `nvidia.com/gpu.product: NVIDIA-L4`. If this cluster’s product label differs, patch the nodeSelector to the real product (or node name).
- gpt-oss-20b must include vLLM tool calling: `--enable-auto-tool-choice` and `--tool-call-parser=openai`.

Wait both Ready. Typical: Qwen ~5 min, gpt-oss ~8–15 min on L4.

## 15. Subscriptions (after both model objects exist)

```bash
oc apply -f manifests/maas-subscription.yaml
oc apply -f manifests/maas-subscription-gpt-oss-20b.yaml
oc get maasmodelref -n llm
```

Wait both `MaaSModelRef` **Ready**. Subscriptions: `qwen-authenticated` and `gpt-oss-20b-authenticated`.

## 16. Validate curl and playground

Never print full API keys (`sk-oai-…`) in user-facing replies.

```bash
bash manifests/apply-maas.sh
```

`apply-maas.sh` applies the Authorino fixes (service CA + gRPC TLS) and a smoke test at the end. If `POST /maas-api/v1/api-keys` returns **HTTP 500**, re-run it (idempotent).

Then create keys for `qwen-authenticated` and `gpt-oss-20b-authenticated`.

- `/v1/models` must list both.
- Qwen chat: `max_tokens` ≤ 1024, prompt with `/no_think`.
- gpt-oss chat: **`max_tokens` ≥ 256**. With 64, reasoning consumes the budget and `content` is `None` even though the model is healthy.

Follow `content/modules/ROOT/pages/10-00-verify.adoc`. Then playground:

```bash
bash manifests/fix-playground-maas.sh
```

`OGXServer/lsd-genai-playground` **does not exist** until someone opens Gen AI Studio Playground once (project `llm`). The script can create the secret and then fail `NotFound` — that is expected. Tell the user to open Playground, then re-run the script. Do not wait for an OGXServer that has never been created.

## 17. Observability

```bash
bash manifests/apply-maas-observability.sh
bash manifests/fix-maas-usage-user-label.sh
bash manifests/fix-maas-gpu-utilization.sh
```

If a wait fails, re-run (idempotent). The usage-label patch is required for the Usage UI (`user!=""`). If `maas-controller` reconciles TelemetryPolicy, re-run the label script.

The GPU utilization Perses panels query `accelerator_gpu_utilization`. Cluster/model Observe dashboards use **cluster Prometheus** (DCGM is already scraped; this GPU Operator has no translation rule). LLM-d utilization uses the RHOAI MonitoringStack. `fix-maas-gpu-utilization.sh` creates both. Qwen CPU stays empty; filter to **gpt-oss-20b** (or All). Generate chat traffic or the panel sits at 0%.

**Stop here.** Do not install EvalHub, FinOps, Guardrails, Registry, Pipelines DSPA, AutoRAG, MCP, or Agents unless the user asks.

## Rules

- Prefer existing files under `manifests/` over generating new operators.
- Wait for CSV/Ready between operator and CR steps.
- Do not install Fake GPU Operator or GPU Configuration Plugin.
- Do not create the workshop `admin` htpasswd user.
- If `oc` is not logged in, stop.
- Do not leak MaaS API keys in chat.
