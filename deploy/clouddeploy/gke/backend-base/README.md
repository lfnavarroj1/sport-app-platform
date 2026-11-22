# backend-base

Carpeta de trabajo del promotor. `scripts/promote_release.py` la llena, en una copia temporal, con `deploy/k8s/base` del backend en el commit exacto de la release validada y comprueba que solo contenga los Deployments, Jobs y Services de la allowlist (`deploy/clouddeploy/allowlist.json`).

Con el componente `deploy/k8s/components/strava-integration` (HU031) el promotor lo copia a `backend-components/strava-integration`, hermano de esta carpeta, y los perfiles `migrations` y `workloads` lo incluyen con `components:`; para renderizar localmente copie también ese componente (o cree uno vacío de `kind: Component`) sin confirmarlo.

En el repositorio solo existe este archivo: los manifiestos del backend nunca se copian a `sport-app-platform`. Para renderizar localmente los perfiles, copie `backend/deploy/k8s/base` aquí sin confirmarlo (está en `.gitignore`).
