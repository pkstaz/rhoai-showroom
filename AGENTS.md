# AGENTS.md

## Objetivo

Workshop **Showroom de Red Hat OpenShift AI 3.5.1** (`rhoai-showroom`): guía hands-on publicada como sitio estático (Antora → GitHub Pages, `https://pkstaz.github.io/rhoai-showroom`) que instala RHOAI en un cluster vacío y deja un modelo LLM publicado en **Models as a Service (MaaS)** servido con **llm-d en CPU**.

El recorrido completo: Web Terminal → operadores/monitoring → RHOAI + dashboard → MaaS (Gateway API/Kuadrant/Postgres) → GPU (NVIDIA/Fake + GPU Booking) → Model Catalog → despliegue de modelos (CPU + hardware profile / GPU / externo TMM) → subscriptions MaaS → verificación → observabilidad → EvalHub/Garak → FinOps → Guardrails → Model Registry → ruteo multi-modelo → AutoML/AutoRAG → Prompt Registry → MCP → AgentOps → Skills plugin.

Regla del lab: **comando / `oc apply` primero** (manifiestos en `manifests/`), la UI es verificación al final de cada módulo. Público: facilitadores y asistentes; el módulo 0.1 mapea Lab→Prd (teoría, qué evaluar) y el 0.2 es la herramienta interactiva RACI y GAPs por cliente (estado por área, validación de gobierno, export Markdown/JSON/print).

## Layout del repo

| Ruta | Contenido |
|---|---|
| `content/modules/ROOT/pages/*.adoc` | Páginas de los módulos (Asciidoc, español), numeradas `NN-MM-tema.adoc` |
| `content/modules/ROOT/nav.adoc` | Menú del sitio (orden y jerarquía de módulos) |
| `content/antora.yml` | Atributos: `rhoai-version: 3.5.1`, `qwen-model`, `page-pagination`, page-links |
| `content/supplemental-ui/` | CSS/JS propios del theme (copy-code, theme-toggle, footer/header) |
| `default-site.yml` | Config Antora: salida a `./www`, UI bundle rhpds, supplemental files |
| `manifests/` | Manifiestos K8s/OpenShift + scripts `apply-*.sh` / `fix-*.sh` (ver `manifests/README.md` para el mapa módulo→path) |
| `www/` | Sitio generado (gitignored) |
| `.github/workflows/gh-pages.yml` | CI: build Antora con Node 20.13.1 y deploy a GitHub Pages en push a `main` |
| `.opencode/skills/` | Skills opencode del repo: `enable-observability` (Módulo 11) y `deploy-on-openshift-pre-provisioned` (desplegar en OpenShift ya desplegado / ambiente pre-configurado, con GPU real L4, salta Fake GPU) |

## Comandos

Preview local (opción 1):

```sh
podman run --rm --name antora -v "$PWD":/antora -p 8080:8080 -i -t ghcr.io/juliaaano/antora-viewer
```

Opción 2:

```sh
npm install --global @antora/cli@3.1 @antora/site-generator@3.1
antora generate default-site.yml
```

Los scripts de `manifests/` se ejecutan desde la **raíz del repo** contra un cluster OpenShift 4.20+ (`oc` logueado, storage class por defecto, Helm 3).

## Estado actual (rama `main`)

- **Validado en lab (módulos 0–8.1, 9–11 aprox.)**: plataforma RHOAI 3.5.1, monitoring, MaaS end-to-end (installers `apply-maas.sh`, `apply-maas-observability.sh` con auto-fix Authorino/gRPC TLS), Qwen3-0.6B en CPU con llm-d, subscriptions, observabilidad (Tempo/OTEL/COO/Loki), EvalHub + MLflow + Garak `quick`, Fake GPU + GPU Booking, DCGM→`accelerator_gpu_utilization`.
- **WIP / no validado en lab** (marcado con `(WIP)` en `nav.adoc` y CAUTION en el intro): módulo **8.2 GPU** (Qwen3-14B-AWQ en L4 con tool parser hermes — commit más reciente), **8.3 modelo externo TMM** y módulos **12–22** (EvalHub avanzado, FinOps, Guardrails, Registry, ruteo, AutoML, AutoRAG, Prompt Registry, MCP, AgentOps, Skills).
- El agente OpenCode del cluster (`manifests/agents/opencode*`, `apply-opencode-agent.sh`) ya está trackeado; falta decidir si entra como módulo propio de la guía.
- Los ficheros `kubeconf-*` de la raíz son kubeconfigs **locales/sensibles** y ya están en `.gitignore` — nunca commitearlos.

## Qué falta

1. **Validar en lab los módulos WIP**: 8.2 (GPU L4 + hermes), 8.3 (TMM externo) y 12–22; quitar las etiquetas `(WIP)` del nav y el CAUTION del intro a medida que se validen.
2. **Terminar el agente OpenCode** (ya trackeado en git; decidir si entra como módulo propio).
3. **GAPs documentados en el módulo 0.1** (salida Lab→Prd): suite de evaluación automatizada con gates de promotion, ART Chatterbox completo + umbral ASR en CI, firma Cosign / promotion firmada del Registry, Guardrails Colang + MCP Gateway, dashboards FinOps de tokens/coste por equipo, trazas LLM (latencia p95, tokens in/out), GPU productiva (MIG + Kueue), GitOps multi-entorno (dev→staging→prod).
4. **Higiene del repo**: mover `kubeconf-*` fuera del repo o a `.gitignore`; revisar el allowlist de gitleaks (apunta a `manifests/maas-postgres.yaml`, que hoy vive en `manifests/maas/`).
5. Sin lint/typecheck: no hay tests; la verificación es `antora generate` (build del sitio) y probar los scripts `apply-*.sh` en cluster.

## Multica

- Proyecto: **RHOAI Showroom** (`647779e4`)
- Agente Multica del repo: **RHOAI Showroom Expert** (`f1da4be9-68d0-4091-8f09-48e042d894ba`) — toda tarea creada en Multica se asigna a este agente (`--assignee-id`), para que arranque a ejecutar en cuanto se registre.
- Flujo estándar de tareas (global): análisis → tareas documentadas en Multica con sección **"Validación"** → `in_review` al terminar. Ver `~/.config/opencode/AGENTS.md`.
