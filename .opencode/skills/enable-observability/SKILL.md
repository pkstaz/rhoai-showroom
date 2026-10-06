---
name: enable-observability
description: "Habilita la observabilidad de RHOAI/MaaS (Módulo 11) en un cluster nuevo con `manifests/apply-maas-observability.sh`: user-workload monitoring, Tempo, OpenTelemetry, COO, Loki + MinIO/LokiStack y usage dashboards. Usar SOLO cuando el usuario pida habilitar/enable observabilidad en este workshop; no para instalar la plataforma ni MaaS."
---

# Enable Observability (Módulo 11)

Instala el stack de observabilidad del showroom: user-workload monitoring → Tempo Operator → OpenTelemetry Operator → Cluster Observability Operator → DSCI monitoring (Perses) → gateway telemetry (MaaS) → Loki Operator → MinIO + LokiStack → `usageLogging`.

Basado en: https://rh-aiservices-bu.github.io/rhoai-maas-guide/modules/main/07-observability.html

## 1. Pre-requisitos (verificar antes de ejecutar)

- `oc` logueado contra el cluster (`oc whoami`; sesión en `~/.kube/config`, nunca kubeconfigs en el repo). Si el token expiró, pedir al usuario el `oc login --token=... --server=...`.
- RHOAI + MaaS ya instalados: `oc get dsci,dsc` (ambos Ready) y `oc get ns | grep models-as-a-service` (Active). Si no, ejecutar primero `apply-maas.sh` — este script asume la plataforma.
- Helm 3 no necesario (todo es `oc apply -k`).

## 2. Ejecución

Desde la **raíz del repo**, en background (los CSVs tardan 5–15 min) y siguiendo el log:

```sh
nohup bash manifests/apply-maas-observability.sh > /tmp/obs-install.log 2>&1 &
tail -f /tmp/obs-install.log
```

El script es idempotente: se puede re-lanzar si falla a mitad.

## 3. Pitfalls conocidos

- **Imágenes MinIO**: `quay.io/minio/minio:latest` y `quay.io/minio/mc:latest` ya NO son pullables (MinIO retiró sus imágenes públicas de quay; Docker Hub también deniega `minio/minio`). Los manifiestos `manifests/observability/usage-logging/minio.yaml` y `manifests/pipelines/minio.yaml` ya están parcheados a `docker.io/bitnamilegacy/minio:latest` y `docker.io/bitnamilegacy/minio-client:latest`. Bitnami es compatible con el manifiesto: el entrypoint hace `exec "$@"`, `minio` y `mc` resuelven en PATH y OpenShift ajusta el PVC vía fsGroup.
- **Job `minio-create-bucket` Failed**: `oc apply` no recrea jobs fallidos → `oc delete job minio-create-bucket -n redhat-ods-monitoring --ignore-not-found` y re-aplicar el kustomization (el script lo hace solo si detecta Failed).
- **Script fallido a mitad** (ej. en la espera de MinIO): completar a mano lo que falte:
  - Paso 8: `oc patch configs.maas.opendatahub.io default --type=merge -p '{"spec":{"usageLogging":true}}'`
- **StorageClass**: el script usa `gp3-csi` si existe (OpenTLC); si no, cae al StorageClass default con un patch al LokiStack.
- **CRDs del Loki Operator**: el CSV queda Succeeded antes de que `lokistacks.loki.grafana.com` esté Established; el script espera el CRD antes del apply del LokiStack.

## 4. Validación (comando + UI)

```sh
oc get csv -n openshift-tempo-operator | grep tempo          # Succeeded
oc get csv -n openshift-opentelemetry-operator | grep opentelemetry  # Succeeded
oc get csv -n openshift-cluster-observability-operator | grep cluster-observability  # Succeeded
oc get csv -n openshift-operators-redhat | grep loki         # Succeeded
oc get lokistack usage -n redhat-ods-monitoring              # Ready
oc get deployment minio -n redhat-ods-monitoring             # Available
oc get telemetrypolicies.extensions.kuadrant.io -n openshift-ingress   # maas-telemetry
oc get envoyfilter maas-model-access-logs -n openshift-ingress         # creado
oc get persesdashboard -n redhat-ods-monitoring              # dashboards usage/model/llm-d
oc get configs.maas.opendatahub.io default -o jsonpath='{.spec.usageLogging}'  # true
```

UI: RHOAI dashboard → **Observe & monitor** → dashboards de usage (tokens/requests por usuario) y llm-d.

## 5. Fix opcional post-install

- Etiqueta de usuario en Usage: `bash manifests/fix-maas-usage-user-label.sh`
- Métricas GPU en Usage: `bash manifests/fix-maas-gpu-utilization.sh` (solo con GPU)
