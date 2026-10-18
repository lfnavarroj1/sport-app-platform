# Preparación de GCP para Terraform y entrega

## Propósito y estado

Esta guía describe la preparación completa de producción de SportApp con el modelo de seguridad aprobado:

- Terraform se ejecuta únicamente desde la estación del operador.
- Ningún workflow de GitHub se autentica contra GCP.
- GCP se conecta en modo lectura a los repositorios y Cloud Build construye dentro de GCP.
- Las imágenes se publican por digest en Artifact Registry.
- Cloud Deploy prepara y ejecuta rollouts con aprobación humana obligatoria.
- Las identidades de construcción, promoción, despliegue e infraestructura están separadas.

> **Estado del código (2026-10-18).** Este modelo está implementado en Terraform y en `deploy/clouddeploy`, validado con `terraform test` y pruebas de scripts, pero **no se ha aplicado en GCP**. El bootstrap ya no crea Workload Identity Federation ni cuentas `ci-delivery-*`; si un estado anterior los contiene, sigue la [migración del retiro de WIF](migracion-retiro-wif-github.md) antes del primer `apply`.

La preparación local está en [Preparación local para Terraform](preparacion-terraform-local.md). La operación detallada de las raíces Terraform está en la [guía de Terraform](../infra/terraform/README.md).

## Contenido

1. [Invariantes de seguridad](#1-invariantes-de-seguridad)
2. [Arquitectura objetivo](#2-arquitectura-objetivo)
3. [Prerrequisitos](#3-prerrequisitos)
4. [Definir identificadores](#4-definir-identificadores)
5. [Crear proyectos y autenticarse](#5-crear-proyectos-y-autenticarse)
6. [Adaptar Terraform al modelo sin acceso desde GitHub](#6-adaptar-terraform-al-modelo-sin-acceso-desde-github)
7. [Ejecutar el bootstrap](#7-ejecutar-el-bootstrap)
8. [Aplicar la infraestructura de producción](#8-aplicar-la-infraestructura-de-producción)
9. [Preparar los repositorios de componentes](#9-preparar-los-repositorios-de-componentes)
10. [Conectar Cloud Build con GitHub](#10-conectar-cloud-build-con-github)
11. [Configurar construcción y publicación](#11-configurar-construcción-y-publicación)
12. [Configurar Cloud Deploy](#12-configurar-cloud-deploy)
13. [Primera release](#13-primera-release)
14. [Releases posteriores y rollback](#14-releases-posteriores-y-rollback)
15. [Suspender, reanudar y destruir](#15-suspender-reanudar-y-destruir)
16. [Archivos y datos sensibles](#16-archivos-y-datos-sensibles)
17. [Verificación de seguridad](#17-verificación-de-seguridad)
18. [Problemas frecuentes](#18-problemas-frecuentes)

## 1. Invariantes de seguridad

Estas reglas no son opcionales:

1. GitHub Actions no recibe `id-token: write`, secretos GCP, llaves JSON ni variables que permitan autenticación.
2. No se configura Workload Identity Federation entre GitHub y GCP.
3. Los repositorios no ejecutan `gcloud`, `kubectl` o Terraform desde GitHub Actions.
4. La cuenta `tf-apply-production` solo puede ser impersonada por operadores humanos declarados.
5. Cloud Build no puede impersonar `tf-apply-production` ni administrar IAM, red, facturación, APIs, Cloud SQL o clústeres.
6. La identidad que construye no aprueba ni ejecuta rollouts.
7. Producción usa imágenes inmutables `@sha256:…`; nunca `latest`.
8. Todo target productivo de Cloud Deploy exige aprobación.
9. Terraform y Cloud Deploy no pueden administrar simultáneamente el mismo atributo de aplicación.
10. No se crean llaves persistentes de cuentas de servicio.

Si una automatización necesita un permiso contrario a estas reglas, detén la configuración y rediseña el límite; no amplíes la cuenta de servicio por conveniencia.

## 2. Arquitectura objetivo

```text
GitHub                                             Google Cloud
┌─────────────────────────┐                       ┌─────────────────────────────┐
│ backend / frontend      │  conexión de lectura │ Cloud Build                │
│ CI, PR, tag y release   │◄─────────────────────│ cuentas build separadas    │
│ sin identidad de GCP    │                       └──────────────┬──────────────┘
└─────────────────────────┘                                      │ imágenes
                                                                 ▼
                                                  ┌─────────────────────────────┐
                                                  │ Artifact Registry           │
                                                  │ imágenes por digest         │
                                                  └──────────────┬──────────────┘
                                                                 │ manifiesto de release
                                                                 ▼
                                                  ┌─────────────────────────────┐
                                                  │ Promotor de plataforma      │
                                                  │ prepara Cloud Deploy        │
                                                  └──────────────┬──────────────┘
                                                                 │ aprobación humana
                                                                 ▼
                                                  ┌─────────────────────────────┐
                                                  │ Cloud Deploy                │
                                                  │ GKE y Cloud Run             │
                                                  └─────────────────────────────┘

Operador ── ADC + impersonación ──► tf-apply-production ──► Terraform
```

La conexión de repositorio permite que GCP lea una revisión. No entrega una identidad GCP al repositorio.

### 2.1 Responsabilidades

| Actor | Puede | No puede |
| --- | --- | --- |
| GitHub Actions | validar, probar, construir localmente y publicar evidencia GitHub | autenticarse o modificar GCP |
| Cloud Build backend | probar, construir y publicar imágenes backend | desplegar o crear infraestructura |
| Cloud Build frontend | probar, construir y publicar `web` | desplegar o crear infraestructura |
| Promotor de plataforma | crear releases de Cloud Deploy con digests aprobados | aprobar rollouts o aplicar Terraform |
| Cloud Deploy | actualizar workloads permitidos | cambiar IAM, redes o infraestructura compartida |
| Operador | aprobar rollouts e impersonar Terraform | compartir credenciales con CI |
| `tf-apply-production` | aplicar las raíces Terraform | ser usada por GitHub, Cloud Build o Cloud Deploy |

### 2.2 Topología de ejecución

| Artefacto | Destino |
| --- | --- |
| `web` | Cloud Run |
| `bff-web` | Cloud Run |
| `bff-mobile` | Cloud Run |
| APIs, publicadores, proyectores y consumidores backend | GKE |
| Jobs de migración | GKE, antes del rollout dependiente |

## 3. Prerrequisitos

### 3.1 Herramientas de la estación

| Herramienta | Verificación |
| --- | --- |
| Terraform ≥ 1.11 | `terraform version` |
| Google Cloud CLI | `gcloud version` |
| Git | `git version` |
| `kubectl` | `kubectl version --client` |
| PowerShell 7 recomendado | `$PSVersionTable.PSVersion` |

Instalación en Windows:

```powershell
winget install --id Hashicorp.Terraform -e
winget install --id Google.CloudSDK -e
winget install --id Git.Git -e
winget install --id Kubernetes.kubectl -e
```

### 3.2 Autoridad inicial

El usuario que prepara GCP necesita temporalmente capacidad para:

- crear y vincular proyectos;
- aplicar el bootstrap;
- crear presupuestos;
- crear cuentas de servicio y sus bindings iniciales;
- instalar la GitHub App de Cloud Build en los repositorios autorizados.

Después del bootstrap, la operación normal usa impersonación y permisos mínimos. Evita conservar `Owner` si ya no es necesario.

## 4. Definir identificadores

Los ID de proyecto son únicos globalmente y no se pueden cambiar. Usa dos proyectos:

- **gestión:** estado Terraform, Cloud Build, conexiones de código y Cloud Deploy;
- **producción:** Artifact Registry y cargas de SportApp.

En una terminal temporal:

```powershell
$billing    = "XXXXXX-XXXXXX-XXXXXX"
$mgmt       = "sportapp-mgmt-1234"
$production = "sportapp-prod-1234"
$region     = "us-central1"
$operator   = "usuario@dominio.com"
```

Opcionalmente guárdalos en `platform\.env.ps1`, ignorado por Git:

```powershell
# No guardar tokens, contraseñas ni llaves en este archivo.
$billing    = "XXXXXX-XXXXXX-XXXXXX"
$mgmt       = "sportapp-mgmt-1234"
$production = "sportapp-prod-1234"
$region     = "us-central1"
$operator   = "usuario@dominio.com"
```

Significado de las variables:

| Variable | Significado |
| --- | --- |
| `$billing` | ID de la cuenta de facturación de Google Cloud que se vinculará a los proyectos. Tiene el formato `XXXXXX-XXXXXX-XXXXXX`, se obtiene con `gcloud billing accounts list` y no es una contraseña. |
| `$mgmt` | ID globalmente único del proyecto de gestión. Aloja el estado remoto de Terraform, Cloud Build, Cloud Deploy y las cuentas de servicio de entrega. `sportapp-mgmt-1234` es solo un ejemplo. |
| `$production` | ID globalmente único del proyecto donde se ejecuta SportApp. Aloja GKE, Cloud Run, Cloud SQL, Artifact Registry, Pub/Sub, Secret Manager y la observabilidad de producción. `sportapp-prod-1234` es solo un ejemplo. |
| `$region` | Región principal donde se crean los recursos regionales. SportApp usa `us-central1`; debe conservarse de forma consistente en Terraform y en los servicios de construcción y despliegue. |
| `$operator` | Correo de la persona autorizada para ejecutar Terraform e impersonar las cuentas de servicio de plan y aplicación. Debe corresponder a una cuenta humana de Google. |

Los valores `1234` y `XXXXXX-XXXXXX-XXXXXX` son marcadores de ejemplo y deben reemplazarse antes de ejecutar los comandos. Ninguna de estas variables contiene credenciales; la autenticación se realiza con ADC e impersonación.

Carga el archivo con:

```powershell
. .\.env.ps1
```

## 5. Crear proyectos y autenticarse

### 5.1 Autenticación humana

```powershell
gcloud auth login
gcloud auth application-default login
gcloud auth list
```

ADC crea un archivo fuera del repositorio, en `%APPDATA%\gcloud`. No lo copies al proyecto.

### 5.2 Proyectos y facturación

```powershell
gcloud projects create $mgmt --name="SportApp gestion"
gcloud projects create $production --name="SportApp produccion"
gcloud billing projects link $mgmt --billing-account=$billing
gcloud billing projects link $production --billing-account=$billing
```

Verifica:

```powershell
gcloud billing projects describe $mgmt
gcloud billing projects describe $production
```

### 5.3 Políticas de credenciales

Cuando la organización lo permita, aplica restricciones que impidan crear o subir llaves de cuentas de servicio. No descargues archivos JSON y no agregues `credentials = file(...)` a los proveedores Terraform.

## 6. Adaptar Terraform al modelo sin acceso desde GitHub

Esta adaptación ya está en el código de `sport-app-platform`. La sección explica qué hace cada raíz para que el plan pueda revisarse con criterio.

| Raíz | Proyecto | Administra |
| --- | --- | --- |
| `bootstrap/gcp-state` | gestión | estado, `tf-plan`/`tf-apply` (solo operadores), identidades de entrega y sus roles de proyecto |
| `environments/production` | producción | infraestructura, Artifact Registry separado, Cloud Run base, permisos cruzados de `cloud-deploy-execution` |
| `environments/production-workloads` | producción | namespace, KSA, Secrets, ConfigMap, Services y RBAC; nunca Deployments ni Jobs |
| `environments/delivery` | gestión | conexión de Cloud Build, triggers, evidencia, promotor, pipelines y targets |

### 6.1 Retirar el diseño anterior

El bootstrap ya no crea ni autoriza (con un estado anterior, el plan los destruye o los olvida según la [migración](migracion-retiro-wif-github.md)):

- `google_iam_workload_identity_pool.github`;
- el provider OIDC de GitHub;
- bindings `plan_github`, `apply_github` y `delivery_github`;
- cuentas `ci-delivery-*` usadas directamente por repositorios;
- variables `github_repository` y `component_repositories` para autenticación GCP;
- salidas `workload_identity_provider` y `delivery_service_accounts`.

Las políticas IAM de `tf-plan-production` y `tf-apply-production` son autoritativas: solo `roles/iam.serviceAccountTokenCreator` para los `operators` (personas o grupos, validado). Cualquier binding de GitHub, Cloud Build o Cloud Deploy sobre esas cuentas desaparece en el siguiente apply. `tf-plan-production` se conserva para planes manuales de revisión, de solo lectura.

### 6.2 Crear identidades separadas

El bootstrap crea, con `delivery = true` en el ambiente y nombres parametrizables en `delivery_account_ids`:

| Cuenta | Proyecto | Permiso funcional |
| --- | --- | --- |
| `tf-apply-production` | gestión | aplicación manual de infraestructura |
| `cloud-build-backend` | gestión | build y escritura en repositorio backend de Artifact Registry |
| `cloud-build-frontend` | gestión | build y escritura en repositorio frontend de Artifact Registry |
| `release-promoter` | gestión | crear releases en pipelines Cloud Deploy existentes |
| `cloud-deploy-execution` | gestión | ejecutar rollouts autorizados sobre targets productivos |

Usa cuentas distintas aunque inicialmente una sola persona opere el sistema.

| Cuenta | Permisos concretos |
| --- | --- |
| `cloud-build-backend` | `logging.logWriter`; `artifactregistry.writer` solo en `sportapp-backend`; `storage.objectCreator` solo en su bucket de evidencia; `cloudbuild.readTokenAccessor` en la conexión |
| `cloud-build-frontend` | lo mismo, pero solo en `sportapp-frontend` y su bucket |
| `release-promoter` | `logging.logWriter`; lectura de ambos buckets de evidencia y ambos repositorios; `clouddeploy.releaser` en cada pipeline; escritura en el bucket de fuentes; `iam.serviceAccountUser` solo sobre `cloud-deploy-execution` |
| `cloud-deploy-execution` | `logging.logWriter` y `clouddeploy.jobRunner` en gestión; lectura de ambos repositorios; `container.clusterViewer` en producción más un `Role` de Kubernetes limitado al namespace; `run.developer` solo en los tres servicios de Cloud Run y `iam.serviceAccountUser` solo sobre sus cuentas |

Solo `tf-apply-production` puede adjuntar estas cuentas a triggers y targets (`iam.serviceAccountUser` a nivel de cuenta). Los tokens los obtienen los agentes de servicio de Cloud Build y Cloud Deploy. Ninguna puede impersonar ni adjuntar `tf-apply-production`, aprobar rollouts ni modificar Binary Authorization.

### 6.3 Permisos prohibidos para automatización

Ninguna cuenta de construcción, promoción o despliegue debe recibir:

- `roles/owner` o `roles/editor`;
- administración de IAM o cuentas de servicio;
- `iam.serviceAccounts.actAs` sobre `tf-apply-production`;
- administración de proyectos, facturación o APIs;
- administración de VPC, subredes, firewalls o Cloud SQL;
- permisos para modificar políticas de Binary Authorization;
- permisos para aprobar sus propios rollouts.

### 6.4 Separar propiedad Terraform/Cloud Deploy

Antes de habilitar releases automáticas, asigna un solo propietario por campo:

| Recurso/campo | Propietario |
| --- | --- |
| Proyectos, APIs, VPC, GKE, Cloud SQL, Pub/Sub, IAM, secretos | Terraform |
| Namespace, KSA, bindings Workload Identity, Services y configuración compartida | Terraform |
| Imagen y revisión de Cloud Run | Cloud Deploy |
| Deployments, Jobs de migración y sus imágenes en GKE | Cloud Deploy |

Implementación:

1. `production-workloads` solo aplica Services del backend; Deployments y Jobs los aplica Cloud Deploy desde `deploy/clouddeploy/gke`. Un estado anterior los olvida con bloques `removed`, sin borrarlos.
2. El ConfigMap `sportapp-runtime` tiene nombre fijo para que los manifiestos de Cloud Deploy lo referencien.
3. En Cloud Run, `lifecycle.ignore_changes` cubre solo imagen, revisión, tráfico, etiquetas y anotaciones de la plantilla, y el cliente del último despliegue. Las plantillas de Cloud Deploy reciben el resto de la configuración como parámetros del target, tomados de Terraform; `environments/delivery` falla si plantilla y Terraform no coinciden.
4. Pruebas: `modules/gcp/cloud-run/tests` demuestra que un digest posterior no se restaura y que un cambio de configuración sí se aplica; `production-workloads/tests` y `tests/test_politicas.py` fallan si Terraform vuelve a administrar Deployments, Jobs o digests.

Después de la primera release ejecuta `terraform plan` en `production` y `production-workloads`: no debe proponer cambios de imagen ni de cargas.

### 6.5 Recursos de entrega que Terraform debe crear

En el proyecto de gestión:

- APIs de Cloud Build, conexión de repositorios, Cloud Deploy, Pub/Sub/Eventarc si se automatiza la promoción, Logging y KMS si se firman attestations;
- cuentas de servicio separadas;
- buckets de logs/evidencia con retención;
- conexiones y repositorios remotos de Cloud Build;
- triggers de backend y frontend;
- pipelines y targets Cloud Deploy;
- target productivo con aprobación requerida.

En producción:

- Artifact Registry;
- GKE y Cloud Run;
- permisos cruzados mínimos para las identidades del proyecto de gestión;
- Binary Authorization, si se activa;
- logs y alertas de despliegue.

## 7. Ejecutar el bootstrap

### 7.1 Completar variables

Después de adaptar el código según la sección 6:

```powershell
cd infra\terraform\bootstrap\gcp-state
Copy-Item bootstrap.auto.tfvars.example bootstrap.auto.tfvars
notepad bootstrap.auto.tfvars
```

El archivo debe contener, como mínimo:

| Campo | Valor |
| --- | --- |
| proyecto de gestión | `$mgmt` |
| región | `$region` |
| proyecto de producción | `$production` |
| operadores | `user:$operator` (solo `user:` o `group:`) |
| `delivery = true` en `production` | crea las identidades de Cloud Build y Cloud Deploy |
| cuenta de facturación | `$billing` |
| presupuesto y alertas | valores aprobados |

No configures repositorios GitHub como principals de cuentas GCP.

### 7.2 Plan y apply manual

```powershell
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
terraform output
```

Antes de aplicar confirma que el plan:

- elimina cualquier provider/binding OIDC de GitHub anterior;
- no crea llaves de cuentas de servicio;
- autoriza `tf-apply-production` solo a operadores;
- crea identidades separadas para build, promoción y despliegue;
- crea presupuesto y bucket de estado.

Respalda el estado inicial del bootstrap o migra su backend siguiendo `versions.tf`.

## 8. Aplicar la infraestructura de producción

### 8.1 Archivos locales

```powershell
cd ..\..\environments\production
Copy-Item gcp.auto.tfvars.example gcp.auto.tfvars
Copy-Item backend.hcl.example backend.hcl
notepad gcp.auto.tfvars
notepad backend.hcl
```

`gcp.auto.tfvars` debe declarar:

- `$production` como proyecto;
- la cuenta `tf-apply-production` como identidad a impersonar;
- correos de alertas;
- redes autorizadas solo cuando sean indispensables;
- `delivery_identities` con la salida del bootstrap: cada cuenta de Cloud Build queda como writer únicamente de su repositorio (`sportapp-backend` o `sportapp-frontend`) y las de promoción y ejecución solo leen.

`backend.hcl` debe declarar el bucket de estado y la impersonación de `tf-apply-production`. Ambos archivos permanecen fuera de Git.

### 8.2 Verificar impersonación

```powershell
$tfApply = "tf-apply-production@$mgmt.iam.gserviceaccount.com"
gcloud auth print-access-token --impersonate-service-account=$tfApply
```

Un `403` indica que el operador no tiene `roles/iam.serviceAccountTokenCreator` sobre esa cuenta concreta.

### 8.3 Crear infraestructura base

```powershell
terraform init -backend-config=backend.hcl -reconfigure
terraform validate
terraform test
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
```

La primera aplicación puede dejar Cloud Run sin servicios si aún no existen imágenes aprobadas. No uses imágenes públicas o tags mutables como marcador. Primero construye la release inicial y luego realiza la creación controlada descrita en la sección 13.

### 8.4 Producción GKE

La raíz `production-workloads` solo debe aplicarse después de completar la separación de propiedad de la sección 6.4.

```powershell
cd ..\production-workloads
Copy-Item gcp.auto.tfvars.example gcp.auto.tfvars
Copy-Item backend.hcl.example backend.hcl
terraform init -backend-config=backend.hcl -reconfigure
terraform validate
terraform test
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
```

El plan no debe incluir Deployments ni Jobs que pasarán a ser administrados por Cloud Deploy.

## 9. Preparar los repositorios de componentes

Backend y frontend deben implementar el siguiente contrato.

### 9.1 GitHub Actions

- CI de push/PR y validación de release.
- `permissions: contents: read` como base.
- sin `id-token: write`.
- sin `google-github-actions/auth`.
- sin `gcloud`, `kubectl`, Terraform o push a Artifact Registry.
- sin secrets o variables GCP.

Comprueba en cada repositorio:

```powershell
rg -n "google-github-actions/auth|id-token: write|GCP_|gcloud|kubectl|terraform" .github/workflows
```

El resultado debe estar vacío o limitarse a comentarios que expliquen la prohibición.

### 9.2 Configuración Cloud Build

Cada repositorio conserva un archivo `cloudbuild.release.yaml` que:

1. valida la versión;
2. ejecuta pruebas completas;
3. construye una sola vez;
4. publica imágenes por versión y commit;
5. resuelve los digests;
6. produce `backend-release.json` o `frontend-release.json`;
7. no despliega y no modifica infraestructura.

La identidad no se declara ni se almacena en el repositorio: la asigna el trigger creado por Terraform. Las sustituciones que envía cada trigger son exactamente las que declara su archivo:

| Trigger | Sustituciones | Evidencia |
| --- | --- | --- |
| `release-backend` | `_AR_LOCATION`, `_AR_PROJECT`, `_AR_REPOSITORY=sportapp-backend`, `_RELEASE_BUCKET` | `gs://<bucket backend>/sport-app-backend/<tag>/backend-release.json` |
| `release-frontend` | `_REGISTRY`, `_REPOSITORY=sportapp-frontend`, `_RELEASE_BUCKET` | `gs://<bucket frontend>/frontend/<tag>/frontend-release.json` |

Formatos aceptados: [`schemas/backend-release.schema.json`](../schemas/backend-release.schema.json) y [`schemas/frontend-release.schema.json`](../schemas/frontend-release.schema.json).

### 9.3 Manifiesto de salida

El promotor acepta únicamente manifiestos que incluyan:

- repositorio y commit;
- tag SemVer;
- identificador de Cloud Build exitoso;
- contrato esperado;
- imágenes `Artifact Registry@sha256`;
- resultados de pruebas y checksums;
- ninguna referencia `latest`.

## 10. Conectar Cloud Build con GitHub

Este procedimiento se realiza desde GCP una sola vez, preferiblemente declarado por Terraform y aplicado por el operador.

### 10.1 Instalar la conexión

Terraform (`environments/delivery`, primer apply con `github_connection_ready = false`) crea la conexión `github` en la región del plano de entrega, pendiente de autorización. El **único paso manual** es autorizarla, una vez:

1. En el proyecto de gestión, abre **Cloud Build → Repositorios (2.ª gen.)** y selecciona la conexión `github` de la región.
2. Pulsa **Terminar la configuración** e inicia sesión en GitHub con una cuenta administradora de `lfnavarroj1`.
3. Instala la GitHub App de Cloud Build **solo** en `sport-app-backend`, `sport-app-frontend` y `sport-app-platform` (este último lo lee el promotor). Cloud Build guarda el token OAuth en Secret Manager del proyecto de gestión: no pasa por Terraform, por GitHub Actions ni por tu equipo.
4. Comprueba que la conexión quedó instalada:

   ```powershell
   gcloud builds connections describe github --region=$region --project=$mgmt --format="value(installationState.stage)"
   ```

   Debe responder `COMPLETE`.

5. Cambia `github_connection_ready = true` en `gcp.auto.tfvars` de `environments/delivery` y aplica un plan nuevo: crea los repositorios vinculados y los triggers (deshabilitados).

No agregues secretos GCP en GitHub. La instalación permite a GCP leer GitHub; no permite a GitHub asumir una cuenta de servicio. Terraform no reconcilia `github_config` de la conexión porque lo escribe esta autorización.

### 10.2 Crear triggers

Terraform crea dos triggers regionales (deshabilitados mientras `release_triggers_enabled = false`; habilítalos cuando ambos repositorios tengan `cloudbuild.release.yaml` en `main`):

| Trigger | Repositorio | Cuenta | Configuración |
| --- | --- | --- | --- |
| `release-backend` | backend | `cloud-build-backend` | `cloudbuild.release.yaml` |
| `release-frontend` | frontend | `cloud-build-frontend` | `cloudbuild.release.yaml` |

Filtros:

- evento: tag push;
- patrón: `^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$`;
- región: la misma del plano de entrega;
- cuenta administrada por el usuario, nunca la predeterminada;
- logs en bucket dedicado o Cloud Logging;
- sustituciones con proyecto, región, repositorio y bucket de evidencia.

El trigger debe fijar la cuenta de servicio; un cambio en el repositorio no puede elegir una cuenta más privilegiada.

### 10.3 Probar sin publicar una release productiva

Usa un tag de prueba en un repositorio o fork no productivo y confirma:

- el build puede leer código;
- solo escribe en su repositorio de Artifact Registry;
- no puede listar secretos ni modificar Cloud Run/GKE;
- no puede impersonar `tf-apply-production`;
- produce el manifiesto de salida esperado.

Elimina los artefactos de prueba después de verificar la política de retención.

## 11. Configurar construcción y publicación

### 11.1 Artifact Registry

Usa repositorios separados o permisos separados por prefijo para backend y frontend. Las cuentas de construcción reciben solo escritura en el destino que les corresponde. Las identidades de ejecución reciben solo lectura.

Configura:

- tags inmutables;
- limpieza de imágenes no etiquetadas;
- conservación de releases recientes;
- análisis de vulnerabilidades;
- alertas ante builds o pushes fallidos.

### 11.2 Separación de build y promoción

Cloud Build finaliza después de publicar el digest y el manifiesto. Un segundo proceso, propiedad de `sport-app-platform`, valida el manifiesto y prepara Cloud Deploy.

El promotor es el trigger manual `promote-release` ([`cloudbuild.promote.yaml`](../cloudbuild.promote.yaml) y [`scripts/promote_release.py`](../scripts/promote_release.py), desde `main` de la plataforma). El operador lo ejecuta desde la consola de GCP o con su propio `gcloud`; nunca desde GitHub:

```powershell
gcloud builds triggers run promote-release --region=$region --project=$mgmt `
  --branch=main --substitutions="_COMPONENT=backend,_VERSION=v1.2.0"
gcloud builds triggers run promote-release --region=$region --project=$mgmt `
  --branch=main --substitutions="_COMPONENT=frontend,_VERSION=v0.9.0,_BACKEND_VERSION=v1.2.0"
```

El promotor:

- usa la cuenta `release-promoter`;
- descarga y valida la evidencia: SemVer, repositorio, commit, Cloud Build ID, pruebas, contrato (`expectedBffContract` del frontend frente a `contractVersion` del backend: misma MAJOR y MINOR igual o mayor), allowlist, registro propio y digests; rechaza `latest`, tags e imágenes externas;
- para el backend, lee `deploy/k8s/base` en el commit exacto y rechaza cualquier objeto fuera de la allowlist;
- solo crea releases en los pipelines existentes; no aprueba, no modifica pipelines ni targets y nunca ejecuta Terraform ni `kubectl`;
- deja en su log los checksums y el sha256 de la evidencia, que también quedan como anotaciones de cada release.

Si más adelante se automatiza, usa un evento interno de GCP (build exitoso), nunca un workflow de GitHub.

## 12. Configurar Cloud Deploy

### 12.1 Pipelines y targets

Como Cloud Run administra un servicio por target, usa pipelines/targets explícitos:

| Pipeline | Target productivo | Imagen(es) |
| --- | --- | --- |
| `backend-gke` | clúster y namespace backend | APIs, workers, proyectores y Jobs |
| `bff-web` | servicio Cloud Run `bff-web` | `bff-web` |
| `bff-mobile` | servicio Cloud Run `bff-mobile` | `bff-mobile` |
| `frontend-web` | servicio Cloud Run `web` | `web` |

Todos los targets de producción declaran `require_approval = true` (`environments/delivery`). `backend-gke` tiene dos etapas sobre el mismo clúster y namespace:

| Etapa | Target | Perfil Skaffold | Qué hace |
| --- | --- | --- | --- |
| 1 | `production-gke-migrations` | `migrations` | aplica solo los Jobs de la release (nombres con sufijo propio y su KSA de migración); la verificación espera `Complete` y un Job fallido detiene el rollout |
| 2 | `production-gke` | `workloads` | solo puede promoverse cuando la etapa 1 terminó; aplica los Deployments, Cloud Deploy espera el rollout y la verificación consulta `/health/ready` de cada API |

Así el orden es real: `validar release → Jobs de migración → Complete → Deployments → rollout → smoke`. Cada release crea Jobs nuevos y repetir un rollout no vuelve a ejecutar una migración terminada. Cloud Deploy no ejecuta dos rollouts a la vez sobre el mismo target. No existe rollback destructivo automático de la base.

### 12.2 Configuración controlada por la plataforma

Guarda en `sport-app-platform`:

- definición de pipelines y targets;
- configuración Skaffold;
- plantillas Cloud Run;
- overlay productivo GKE;
- mapeo entre imágenes y Deployments;
- verificaciones y procedimientos de rollback.

Está en [`deploy/clouddeploy`](../deploy/clouddeploy): [`allowlist.json`](../deploy/clouddeploy/allowlist.json) (componentes, pipelines, imágenes y objetos Kubernetes permitidos), `gke/skaffold.yaml` con los perfiles `migrations` y `workloads`, los overlays de Kustomize y `cloudrun/<servicio>/` con `service.yaml` y su smoke. Los manifiestos del componente pueden definir su contrato técnico, pero el promotor solo acepta campos e imágenes de la allowlist y ninguna verificación ni hook proviene de la release del componente.

Las verificaciones de GKE usan `deploy_tools_image` (gcloud, kubectl y `gke-gcloud-auth-plugin`, por digest; variable obligatoria de `environments/delivery`) y las de Cloud Run, `run_verify_image` (gcloud y curl).

### 12.3 Cuenta de ejecución

`cloud-deploy-execution` debe poder:

- leer imágenes aprobadas;
- actualizar los servicios Cloud Run permitidos;
- operar únicamente en el namespace productivo de GKE;
- consultar rollouts y logs necesarios.

En GKE combina IAM con Kubernetes RBAC. No uses `cluster-admin`.

### 12.4 Aprobadores

`approvers` (en `environments/delivery`) recibe `roles/clouddeploy.approver` en cada pipeline y solo admite `user:` o `group:`. No se asigna a:

- Cloud Build;
- `release-promoter`;
- `cloud-deploy-execution`;
- cuentas de los workloads.

### 12.5 Binary Authorization

Deshabilitada por defecto (`binary_authorization = { enabled = false }` en `environments/production`). Al habilitarla con al menos un attestor, Terraform crea la política del proyecto (`REQUIRE_ATTESTATION`, siempre por digest) y la aplica en GKE y Cloud Run. El permiso para cambiar la política queda en `tf-apply-production` (`binaryauthorization.policyEditor`); las cuentas de entrega no reciben ningún rol de Binary Authorization. Habilítala solo cuando el build produzca attestations válidas.

## 13. Primera release

La primera release resuelve la dependencia entre infraestructura e imágenes: Cloud Run necesita un digest para crear su primera revisión y Cloud Deploy necesita servicios y targets existentes. Todos los `apply` se hacen desde la estación del operador con un plan guardado y revisado.

1. **Aplicar bootstrap e infraestructura base.** Bootstrap ([7](#7-ejecutar-el-bootstrap)), después `environments/production` con `cloud_run_images` vacío ([8](#8-aplicar-la-infraestructura-de-producción)) y `environments/production-workloads` ([8.4](#84-producción-gke)).
2. **Crear Artifact Registry e identidades.** El bootstrap creó las cuatro identidades y `production` los repositorios `sportapp-backend` y `sportapp-frontend` con sus writers y readers. Compruébalo:

   ```powershell
   terraform -chdir=infra\terraform\environments\production output artifact_registry_urls
   terraform -chdir=infra\terraform\bootstrap\gcp-state output delivery_identities
   ```

3. **Autorizar la GitHub App.** Aplica `environments/delivery` con `github_connection_ready = false`, autoriza la conexión ([10.1](#101-instalar-la-conexión)) y vuelve a aplicar con `github_connection_ready = true`.
4. **Habilitar los triggers.** Cuando backend y frontend tengan `cloudbuild.release.yaml` en `main`, aplica `delivery` con `release_triggers_enabled = true`.
5. **Crear los tags.** En backend y frontend, publica las releases SemVer desde `main` (`vX.Y.Z`), según el [manual de versionado](manual-versionado.md).
6. **Esperar Cloud Build.** Comprueba que `release-backend` y `release-frontend` terminaron en `SUCCESS`:

   ```powershell
   gcloud builds list --region=$region --project=$mgmt --filter="trigger_id:*" --limit=5
   ```

7. **Verificar los digests.** Lee la evidencia y compara commit, contrato y digests con los tags:

   ```powershell
   gcloud storage cat gs://$mgmt-delivery-evidence-backend/sport-app-backend/v1.2.0/backend-release.json
   gcloud storage cat gs://$mgmt-delivery-evidence-frontend/frontend/v0.9.0/frontend-release.json
   gcloud artifacts docker images list us-central1-docker.pkg.dev/$production/sportapp-backend --include-tags --limit=20
   ```

8. **Crear Cloud Run con esos digests.** Copia en `cloud_run_images` de `environments/production/gcp.auto.tfvars` los digests de `web`, `bff-web` y `bff-mobile` de la evidencia (nunca un tag), genera el plan, revísalo y aplícalo. Ese digest solo crea la primera revisión.
9. **Registrar pipelines y targets.** Aplica `environments/delivery` otra vez: con los servicios ya creados registra los targets de Cloud Run (los de GKE y `backend-gke` ya existen). Comprueba:

   ```powershell
   gcloud deploy delivery-pipelines list --region=$region --project=$mgmt
   gcloud deploy targets list --region=$region --project=$mgmt --format="table(name,requireApproval)"
   ```

   Todos los targets deben mostrar `requireApproval: True`.
10. **Ejecutar el promotor.** Primero el backend y después el frontend ([11.2](#112-separación-de-build-y-promoción)).
11. **Revisar y aprobar.** En **Cloud Deploy → backend-gke**, revisa en la release las anotaciones (commit, Cloud Build, contrato, sha256 de la evidencia) y los digests. Aprueba `production-gke-migrations`; cuando termine, promueve y aprueba `production-gke`. Aprueba después `bff-web`, `bff-mobile` y `frontend-web`. Rechaza si aparece un tag mutable, un commit distinto, una imagen externa o un target inesperado.

    ```powershell
    gcloud deploy releases promote --release=<release> --delivery-pipeline=backend-gke --region=$region --project=$mgmt
    gcloud deploy rollouts approve <rollout> --release=<release> --delivery-pipeline=backend-gke --region=$region --project=$mgmt
    ```

12. **Verificar GKE y Cloud Run.** Las verificaciones de Cloud Deploy deben terminar en `SUCCEEDED`. Revisa además:

    ```powershell
    gcloud container clusters get-credentials <clúster> --location=us-central1 --project=$production --dns-endpoint
    kubectl -n sportapp get deployments,jobs
    gcloud run services list --project=$production --region=us-central1
    ```

13. **Ejecutar un nuevo `terraform plan`** en `production`, `production-workloads` y `delivery`.
14. **Confirmar que Terraform no revierte imágenes ni cargas.** Los planes no deben proponer cambios de imagen, revisión o tráfico en Cloud Run ni crear, modificar o borrar Deployments o Jobs. Si lo hacen, no apliques: revisa la sección [6.4](#64-separar-propiedad-terraformcloud-deploy).
15. **Registrar la composición.** En la rama de release de la plataforma, completa [`release-manifest.yaml`](../release-manifest.yaml) con versiones, tags, commits, contratos y digests promovidos, y crea su copia `releases/vX.Y.Z.yaml`, según el [esquema de CI y release](esquema-ci-y-release.md).

## 14. Releases posteriores y rollback

### 14.1 Flujo normal

```text
Tag SemVer del componente
  → Cloud Build construye una vez, prueba y publica por digest
  → backend-release.json / frontend-release.json
  → promote-release (manual, en GCP)
  → releases de Cloud Deploy pendientes de aprobación
  → aprobación humana
  → migraciones (backend) y Complete
  → rollout y verificación (readiness y smoke)
```

Terraform no participa en una release que solo cambia código o imagen. Si cambian infraestructura, configuración compartida, IAM, red o servicios, realiza primero un cambio Terraform manual y separado. Si cambia una variable de Cloud Run, actualiza también su plantilla en `deploy/clouddeploy/cloudrun`: `environments/delivery` no aplica targets cuyos parámetros no coincidan.

### 14.2 Rollback

Siempre es una nueva acción de Cloud Deploy, con aprobación humana, readiness y smoke; nunca se mueven tags ni se reconstruye una imagen.

1. Identifica la última release saludable y sus digests (anotaciones de la release y evidencia de su tag).
2. **Cloud Run** (`bff-web`, `bff-mobile`, `frontend-web`): vuelve a promover la versión anterior con un sufijo, lo que crea una release nueva con los digests anteriores:

   ```powershell
   gcloud builds triggers run promote-release --region=$region --project=$mgmt `
     --branch=main --substitutions="_COMPONENT=frontend,_VERSION=v0.8.0,_BACKEND_VERSION=v1.2.0,_RELEASE_SUFFIX=rb1"
   ```

3. **Backend en GKE:** usa el rollback del target `production-gke`, que vuelve a desplegar los Deployments de la release anterior sin repetir ni revertir migraciones:

   ```powershell
   gcloud deploy targets rollback production-gke --delivery-pipeline=backend-gke --region=$region --project=$mgmt
   ```

   El rollout resultante también exige aprobación y ejecuta la verificación de readiness y smoke.
4. Aprueba el rollback y verifica readiness y smoke.
5. No reviertas automáticamente una migración destructiva de base de datos. Si la migración no es retrocompatible, sigue el procedimiento específico documentado por backend antes de desplegar código anterior.

## 15. Suspender, reanudar y destruir

### 15.1 Suspender producción

En `infra/terraform/environments/production/terraform.tfvars`:

```hcl
suspended = true
```

Después:

```powershell
cd infra\terraform\environments\production
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
gcloud sql instances list --project $production
gcloud compute instances list --project $production
```

Suspender conserva red, clúster, base, secretos, imágenes y estado; reduce instancias y nodos según la configuración Terraform.

### 15.2 Reanudar

Cambia `suspended = false`, revisa y aplica un plan. Espera a que Cloud SQL y GKE estén listos antes de promover o reintentar rollouts.

### 15.3 Destruir producción

La destrucción elimina datos, imágenes y secretos del proyecto de producción. Exporta lo necesario antes de continuar.

```powershell
cd infra\terraform\environments\production
terraform plan -var="deletion_protection=false" -var="destroy_confirmation=$production" -out=tfplan
terraform show tfplan
terraform apply tfplan

terraform plan -destroy -var="deletion_protection=false" -var="destroy_confirmation=$production" -out=tfplan-destroy
terraform show tfplan-destroy
terraform apply tfplan-destroy
```

Verifica:

```powershell
gcloud container clusters list --project $production
gcloud sql instances list --project $production
```

El proyecto de gestión, el estado Terraform y las identidades de control no se destruyen con la raíz de producción.

## 16. Archivos y datos sensibles

| Archivo/dato | ¿Git? | Observación |
| --- | --- | --- |
| `*.tf`, lock file y pruebas | sí | infraestructura revisable |
| `terraform.tfvars` sin secretos | sí | capacidades y configuración aprobada |
| `*.example` | sí | plantillas |
| `bootstrap.auto.tfvars` | no | proyectos, operador y facturación |
| `gcp.auto.tfvars` | no | IDs, impersonación y correos |
| `backend.hcl` | no | bucket y cuenta a impersonar |
| `.env.ps1` | no | identificadores locales, nunca tokens |
| `terraform.tfstate*`, `tfplan*`, `.terraform/` | no | estado y planes |
| ADC de gcloud | nunca | vive fuera del repositorio |
| llaves JSON | nunca | no deben crearse |
| secretos de aplicación | nunca | Secret Manager |

Antes de cada commit:

```powershell
git status --short
git diff --cached
```

## 17. Verificación de seguridad

### 17.1 GitHub

- [ ] Ningún workflow tiene `id-token: write`.
- [ ] No existen secrets o variables GCP en backend/frontend/platform.
- [ ] No aparece `google-github-actions/auth`.
- [ ] Push y PR no publican ni despliegan.
- [ ] `main` y los tags están protegidos.

### 17.2 IAM y automatización

- [ ] No existe provider WIF para GitHub.
- [ ] No existen llaves de cuentas de servicio.
- [ ] `tf-apply-production` solo admite operadores.
- [ ] Las cuentas build solo escriben en su Artifact Registry.
- [ ] El promotor no puede aprobar.
- [ ] La cuenta de ejecución no puede modificar infraestructura.
- [ ] Los aprobadores son humanos identificables.
- [ ] Cloud Audit Logs permite correlacionar build, aprobación y rollout.

### 17.3 Entrega

- [ ] Todos los targets productivos exigen aprobación.
- [ ] Solo se despliegan referencias por digest.
- [ ] Terraform no propone revertir imágenes administradas por Cloud Deploy.
- [ ] GKE RBAC limita el namespace.
- [ ] Los smoke tests y el rollback fueron probados.
- [ ] Binary Authorization está habilitado o su adopción está registrada como riesgo pendiente.

## 18. Problemas frecuentes

| Síntoma | Causa probable | Acción |
| --- | --- | --- |
| GitHub obtiene un token GCP | todavía existe WIF/binding antiguo | elimina el provider y bindings con Terraform |
| Cloud Build recibe 403 al publicar | writer ausente o repositorio equivocado | corrige el binding del repositorio específico |
| Cloud Build puede modificar Cloud Run | cuenta de build demasiado amplia | retira roles de despliegue inmediatamente |
| Release no llega a Cloud Deploy | promotor no ejecutado o manifiesto inválido | revisa build, digest y logs del promotor |
| Rollout no espera aprobación | target sin `requireApproval` | corrige y registra de nuevo el target antes de producción |
| GKE devuelve `forbidden` | RBAC insuficiente o namespace incorrecto | ajusta el Role/RoleBinding mínimo, no uses cluster-admin |
| Terraform restaura una imagen anterior | propiedad solapada con Cloud Deploy | completa la separación de la sección 6.4 |
| Cloud Run rechaza una imagen | digest ausente, acceso o Binary Authorization | valida URI, reader y attestation |
| `terraform init` no encuentra estado | `backend.hcl` incorrecto | usa la salida exacta del bucket de bootstrap |
| 403 al impersonar Terraform | operador no autorizado | corrige el binding sobre `tf-apply-production` |

## Referencias oficiales

- [Google Cloud: autenticación para Terraform](https://docs.cloud.google.com/docs/terraform/authentication)
- [HashiCorp: backend GCS](https://developer.hashicorp.com/terraform/language/backend/gcs)
- [Cloud Build: triggers](https://docs.cloud.google.com/build/docs/triggers)
- [Cloud Build: cuenta de servicio administrada](https://docs.cloud.google.com/build/docs/securing-builds/configure-user-specified-service-accounts)
- [Cloud Deploy: desplegar aplicaciones](https://docs.cloud.google.com/deploy/docs/deploying-application)
- [Cloud Deploy: promociones y aprobaciones](https://docs.cloud.google.com/deploy/docs/promote-release)
- [Cloud Deploy: targets Cloud Run](https://docs.cloud.google.com/deploy/docs/run-targets)
- [Cloud Deploy: despliegue en GKE](https://docs.cloud.google.com/deploy/docs/deploy-app-gke)
- [Binary Authorization](https://docs.cloud.google.com/binary-authorization/docs/overview)
- [IAM: prácticas para cuentas de servicio](https://docs.cloud.google.com/iam/docs/best-practices-service-accounts)
- [Google Cloud: presupuestos y alertas](https://docs.cloud.google.com/billing/docs/how-to/budgets)
