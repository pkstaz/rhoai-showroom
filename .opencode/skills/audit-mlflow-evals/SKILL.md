---
name: audit-mlflow-evals
description: "Crea el experimento de auditoría en MLflow (Módulo 12.2) con `manifests/apply-mlflow-audit.sh`: experimento qwen3-14b-evals-gpu, dataset de 8 preguntas, params/tags/metrics y 8 trazas LLM (autolog). Usar SOLO cuando el usuario pida preparar/auditar MLflow para los evals de seguridad del workshop; no para lanzar los evals ni instalar EvalHub."
---

# Audit MLflow (Módulo 12.2)

Prepara la capa de rastreo previa a los xref GPU evals: todo lo que después producen los scans queda en el experimento `qwen3-14b-evals-gpu` (dataset, contexto del run y trazas LLM por pregunta).

## 1. Pre-requisitos (verificar antes de ejecutar)

- `oc` logueado (`oc whoami`); sesión en `~/.kube/config`, nunca kubeconfigs en el repo.
- EvalHub + MLflow instalados (`oc get evalhub evalhub -n evalhub`; dashboard *Experiments (MLflow)* visible). Si no: `bash manifests/apply-evalhub.sh` (Módulo 12.00).
- Endpoint del modelo GPU disponible (módulo 8.2). El autolog hace 8 llamadas cortas a Qwen3-14B-AWQ.
- `jq` instalado.

## 2. Ejecución

Desde la **raíz del repo**:

```sh
bash manifests/apply-mlflow-audit.sh
```

Opcionales: `EXPERIMENT_NAME`, `WORKSPACE` (por defecto `llm`), `TRACES=0` (sin autolog). Idempotente: crea el experimento si no existe y un run nuevo por ejecución.

El script hace port-forward corto a `svc/mlflow` (reutiliza uno existente y lo cierra al salir), sube el dataset como artefacto **y** lo registra como input del run (`log-inputs`), y ejecuta el autolog en un venv propio `~/.cache/rhoai-showroom/mlflow-audit-venv`.

## 3. Pitfalls conocidos

- **`Workspace context is required`**: MLflow en RHOAI es multi-workspace. Toda llamada REST necesita header `X-MLFLOW-WORKSPACE: llm` y URL con prefijo `/mlflow`. El script ya lo hace.
- **Python del sistema**: el PATH hermético de los scripts pone `/usr/bin` (Python 3.9 de macOS) primero → venv viejo sin soporte workspace. El script selecciona Python ≥3.10 (`/opt/homebrew/bin/python3`…) y regenera el venv si hace falta; pin `mlflow>=3.10` (soporte workspace desde 3.10).
- **Digest del dataset**: la API rechaza digests >36 caracteres (`'digest' exceeds the maximum length of 36`). El script trunca el sha256 a 36.
- **Errores REST silenciosos**: `curl` sin `-f` devuelve 0 aunque el servidor responda 4xx — el helper `mf` del script detecta `error`/`error_code` en la respuesta y aborta.
- **Autolog sin red**: la primera ejecución descarga `mlflow`+`openai` (~100 MB). Sin internet usa `TRACES=0`.

## 4. Validación (comando + UI)

```sh
oc port-forward -n redhat-ods-applications svc/mlflow 18443:8443 &
TOKEN=$(oc whoami -t); MF=https://localhost:18443/mlflow
H=(-H "X-MLFLOW-WORKSPACE: llm" -H "Authorization: Bearer $TOKEN")

curl -sk "$MF/api/2.0/mlflow/experiments/search" "${H[@]}" \
  -H 'Content-Type: application/json' -d '{"max_results":100}' \
  | jq -r '.experiments[] | "\(.experiment_id) \(.name)"'      # 6 qwen3-14b-evals-gpu
curl -sk "$MF/api/2.0/mlflow/traces?experiment_ids=6" "${H[@]}" | jq '.traces | length'   # 8
```

UI: Dashboard → *Develop & train* → *Experiments (MLflow)* → proyecto `llm` → `qwen3-14b-evals-gpu` → run: pestañas *Inputs* (dataset), *Artifacts* (`datasets/qwen3-14b-audit-evals.jsonl`), *Traces* (8) y *Metrics* (`trazas_llm_ok = 8`).

## 5. Siguiente

`SUBMIT=1 bash manifests/apply-evals-gpu.sh` (skill `run-gpu-evals`, Módulo 12.03).
