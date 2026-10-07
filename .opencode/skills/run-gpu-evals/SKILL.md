---
name: run-gpu-evals
description: "Lanza los evals de seguridad sobre el modelo GPU Qwen3-14B-AWQ (Módulo 12.3) con `manifests/apply-evals-gpu.sh`: Context-aware vulnerability scan (intents) + OWASP LLM top 10 risk scan, registrados en el experimento MLflow qwen3-14b-evals-gpu. Usar SOLO cuando el usuario pida lanzar/ran/run los evals de seguridad o los scans garak sobre el modelo GPU del workshop; no para instalar EvalHub ni crear el experimento MLflow."
---

# Run GPU Evals (Módulo 12.3)

Lanza los dos scans de seguridad (`intents` y `owasp_llm_top10`, provider EvalHub `garak`) contra Qwen3-14B-AWQ y deja resultados (`attack_success_rate` + `scan.report.html`) en MLflow.

## 1. Pre-requisitos (verificar antes de ejecutar)

- `oc` logueado; `jq` instalado.
- EvalHub: `oc get evalhub evalhub -n evalhub`.
- Modelo GPU Ready: `oc get llminferenceservices.serving.kserve.io -n llm` → `qwen3-14b-awq … True` (módulo 8.2). El script lo comprueba.
- Secret `maas-eval-api-key` en `llm` **y** `evalhub` (Fallback MaaS local, Módulo 12.00).
- Experimento MLflow creado (skill `audit-mlflow-evals`, Módulo 12.02) — sin él el script aborta.

## 2. Ejecución

Dry-run primero (imprime los payloads, no crea nada):

```sh
bash manifests/apply-evals-gpu.sh
```

Luego, desde la **raíz del repo**:

```sh
SUBMIT=1 bash manifests/apply-evals-gpu.sh
```

Crea 2 jobs asíncronos. **No lanzar los dos scans a la vez si ya hay un job activo** (el script imprime un AVISO): comparten la GPU y la fase SDG puede agotar el timeout del sidecar.

## 3. Pitfalls conocidos (validado en lab)

- **Auth por sidecar (`api-key:ref`)**: en *simple mode* EvalHub monta el secreto como token-ref y reescribe `model.url` a `http://localhost:8080/v1`. Los roles `judge`/`sdg` del payload **deben** apuntar también al sidecar: contra MaaS directo con el token-ref → `401 AuthenticationError` (litellm) y el job muere en la fase SDG.
- **Timeout del sidecar en SDG**: generaciones largas fallan con `BadGatewayError … context deadline exceeded (Client.Timeout exceeded while awaiting headers)`. El payload fija `sdg_max_tokens: 512` y `sdg_max_concurrency: 6`; `sdg_max_tokens` por defecto es `0` (sin tope) — no quitarlo.
- **Jobs Kubernetes en el namespace del modelo**: los pods corren en `llm`, no en `evalhub`. Logs: `oc logs -n llm <pod> -c adapter | grep 'garak\[progress\]'`.
- **Estado del run padre en MLflow**: EvalHub deja el run parent en `RUNNING` aunque el job termine; mirar los runs hijos (metrics `attack_success_rate`) o el estado del job en la UI de Evaluations.
- **Job atascado**: un job en `running` sin pods en `evalhub`/`llm` no bloquea; borrar con `curl -X DELETE "$EVALHUB_URL/api/v1/evaluations/jobs/<id>?hard_delete=true" -H "Authorization: Bearer $(oc whoami -t)" -H "X-Tenant: llm"`.
- **Imagen Garak**: la primera vez el pod tarda minutos en *Pending* (pull de `odh-trustyai-garak-lls-provider-dsp`).

## 4. Seguimiento

```sh
EVALHUB_URL=https://$(oc get route -n evalhub -o jsonpath='{.items[0].spec.host}')
curl -sk "$EVALHUB_URL/api/v1/evaluations/jobs?limit=5" \
  -H "Authorization: Bearer $(oc whoami -t)" -H "X-Tenant: llm" \
  | jq '.jobs[] | {id: .resource.id[0:8], benchmark: .resource.benchmark_id, state: .resource.state}'
oc get jobs,pods -n llm | grep -E 'garak|qwen3-14b'
```

Tiempos de referencia: OWASP *~30–45 min* (12 045 prompts; ASR ≈ 0.10 en lab); Context-aware *+30–90 min* (SDG sobre GPU).

## 5. Validación (comando + UI)

```sh
oc port-forward -n redhat-ods-applications svc/mlflow 18443:8443 &
TOKEN=$(oc whoami -t); MF=https://localhost:18443/mlflow
curl -sk "$MF/api/2.0/mlflow/runs/search?experiment_ids=6" \
  -H "X-MLFLOW-WORKSPACE: llm" -H "Authorization: Bearer $TOKEN" \
  | jq '.runs[] | {name: .info.run_name, status: .info.status,
       asr: [.data.metrics.attack_success_rate // empty]}'
```

UI: *Develop & train* → *Evaluations* → proyecto `llm` (estado de los jobs) y *Experiments (MLflow)* → `qwen3-14b-evals-gpu` → run del job → metrics `attack_success_rate` + artefactos `scan.report.html` / `scan.report.jsonl` / `scan.hitlog.jsonl`.

Nota de guía: umbral de lab `0.3`; ASR más bajo = más seguro. El modelo del lab no es un modelo alineado: ASR alto esperable en CPU/versión base — el informe es el entregable.
