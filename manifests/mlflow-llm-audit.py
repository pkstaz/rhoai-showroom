#!/usr/bin/env python3
"""Autolog LLM para la auditoría de evals (módulo 12.2).

Envía las preguntas del dataset de auditoría al modelo MaaS y deja una traza
por pregunta en MLflow (mlflow.openai.autolog), ligada al run de auditoría.

Variables de entorno requeridas (las inyecta apply-mlflow-audit.sh):
  MLFLOW_TRACKING_URI, MLFLOW_WORKSPACE, MLFLOW_TRACKING_TOKEN,
  MLFLOW_TRACKING_INSECURE_TLS, MAAS_ENDPOINT, MAAS_KEY, MODEL_ID
"""

import argparse
import json
import os
import sys
import time
import warnings

try:
    from urllib3.exceptions import InsecureRequestWarning

    warnings.simplefilter("ignore", InsecureRequestWarning)
except ImportError:
    pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True, help="Run de auditoría en MLflow")
    parser.add_argument("--dataset", required=True, help="Ruta al JSONL de preguntas")
    parser.add_argument("--max-questions", type=int, default=0, help="0 = todas")
    args = parser.parse_args()

    required = ["MLFLOW_TRACKING_URI", "MLFLOW_WORKSPACE", "MLFLOW_TRACKING_TOKEN",
                "MAAS_ENDPOINT", "MAAS_KEY", "MODEL_ID"]
    missing = [v for v in required if not os.environ.get(v)]
    if missing:
        print(f"ERROR: faltan variables de entorno: {', '.join(missing)}", file=sys.stderr)
        return 2

    try:
        import mlflow
        import mlflow.openai
        from openai import OpenAI
    except ImportError as exc:
        print(f"ERROR: dependencias ausentes ({exc}). Ejecuta: pip install mlflow openai",
              file=sys.stderr)
        return 2

    questions = []
    with open(args.dataset, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                questions.append(json.loads(line))
    if args.max_questions > 0:
        questions = questions[: args.max_questions]
    if not questions:
        print("ERROR: dataset vacío", file=sys.stderr)
        return 2

    endpoint = os.environ["MAAS_ENDPOINT"].rstrip("/")
    model_id = os.environ["MODEL_ID"]
    client = OpenAI(base_url=endpoint, api_key=os.environ["MAAS_KEY"], timeout=120)

    ok = 0
    failed = 0
    with mlflow.start_run(run_id=args.run_id) as run:
        mlflow.openai.autolog()
        for question in questions:
            qid = question.get("id", "?")
            try:
                client.chat.completions.create(
                    model=model_id,
                    messages=[{"role": "user", "content": question["prompt"]}],
                )
                ok += 1
                print(f"  [ok] {qid} ({question.get('categoria', '')})")
            except Exception as exc:  # noqa: BLE001 — una pregunta que falla no aborta el audit
                failed += 1
                print(f"  [WARN] {qid}: {exc}", file=sys.stderr)
            time.sleep(0.2)
        mlflow.log_metric("trazas_llm_ok", ok)
        mlflow.log_metric("trazas_llm_errores", failed)
        run_id = run.info.run_id

    print(f"Trazas LLM: {ok}/{len(questions)} enviadas al run {run_id}")
    if ok:
        print("Ver: Experiments (MLflow) → run → Traces (prompt/respuesta/tokens por pregunta)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
