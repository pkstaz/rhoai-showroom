# Manifests

Kubernetes / OpenShift manifests and helper scripts for the workshop.
Run `oc apply` / scripts from the **repo root**.

| Path | Module |
|---|---|
| `operators/` | Prerequisite operators: base (module 3) + MaaS (module 4), one directory per Operator
| `cluster-monitoring-config.yaml` | User-workload monitoring (module 3 prerequisites) |
| `oauth-htpasswd.yaml` | Optional OAuth htpasswd patch |
| `maas/` | MaaS infra bundle: GatewayClass, Kuadrant, Postgres + kustomization GitOps (`oc apply -k maas`) (module 4) |
| `apply-maas.sh` | MaaS end-to-end installer (operators + connectivity + postgres + gateway + DSC + Authorino auto-fix) |
| `rhoai-operator.yaml` | RHOAI Operator |
| `default-dsc.yaml` | DataScienceCluster |
| `odh-dashboard-config-patch.yaml` | Dashboard flags |
| `apply-maas-gateway.sh` | MaaS Gateway |
| `model-catalog-qwen.yaml` | Model Catalog (HF) |
| `fake-gpu-values.yaml` | Fake GPU topology |
| `hardware-profile-cpu.yaml` | CPU hardware profile `cpu-workshop` (module 3)
| `hardware-profile-nvidia.yaml` | GPU profile `nvidia-gpu` (module 5 NVIDIA)
| `fake-gpu-dashboard/` | DCGM Grafana dashboard + ServiceMonitor for Fake GPU (module 5)
| `llminferenceservice-qwen3-06b.yaml` | llm-d CPU + MaaSModelRef (module 8.1) |
| `llminferenceservice-qwen3-14b-awq.yaml` | llm-d GPU (L4) + MaaSModelRef, tool parser hermes (module 8.2) |
| `llminferenceservice-gpt-oss-20b.yaml` | llm-d GPU + MaaSModelRef (module 8.2 alt) |
| `apply-external-model.sh` | TMM ExternalModel from MODEL_NAME / ENDPOINT / API_KEY (module 8.3) |
| `routing/external-model.yaml` | Template (no secrets; prefer the script) |
| `patch-llmisvc-cpu.sh` | Force vLLM CPU after wizard |
| `maas-subscription.yaml` | Auth policy + subscription (Qwen) |
| `maas-subscription-qwen3-14b-awq.yaml` | Auth policy + subscription (GPU Qwen3-14B-AWQ) |
| `maas-subscription-gpt-oss-20b.yaml` | Auth policy + subscription (GPU) |
| `apply-gpu-booking-hybrid.sh` | GPU Booking with Fake + real NVIDIA (discovery off) |
| `fix-maas-gpu-utilization.sh` | DCGM → `accelerator_gpu_utilization` on cluster Prometheus + RHOAI MonitoringStack |
| `fix-maas-usage-user-label.sh` | Usage UI user label |
| `fix-playground-maas.sh` | Playground API key + max_tokens |
| `observability/` | Tempo, OTEL, COO, Loki, MinIO (module 11) |
| `apply-maas-observability.sh` | Observability stack installer (user-workload monitoring + Tempo + OTEL + COO + Loki + usage) |
| `evalhub/` | EvalHub + MLflow + Garak/ART providers (modules 12–12.1) |
| `apply-evalhub.sh` | TrustyAI + MLflow + EvalHub |
| `apply-garak.sh` | Enable Garak + `garak-kfp`; `SUBMIT=1` smoke `quick`; `MODE=art` Chatterbox |
| `finops/` | Subscriptions free/team (module 13) |
| `guardrails/` | `NemoGuardrails` CPU (+ MaaS template) (module 14) |
| `apply-guardrails.sh` | TrustyAI + NemoGuardrails (`MODE=maas` opcional) |
| `registry/` | Postgres + ModelRegistry workshop (module 15) |
| `apply-registry.sh` | Model Registry installer |
| `pipelines/` | MinIO + DSPA AutoML/AutoRAG (modules 17–18) |
| `apply-pipelines.sh` | Pipeline server |
| `autorag/` | pgvector + vector-stores ConfigMap (module 18) |
| `apply-autorag-store.sh` | Vector store |
| `mcp/` | OpenShift MCPServer + Playground CM (module 20) |
| `apply-mcp.sh` | MCP Lifecycle Operator + server |
| `agents/` | Workshop A2A agent source + deploy (module 21) |
| `apply-agent.sh` | Build (internal registry or QUAY_IMAGE) + deploy |
| `apply-skills.sh` | Console plugin https://github.com/eformat/openshift-skills-plugin |
