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

## Cómo usar esta guía

La preparación se divide por ciclo de vida. No repitas todos los pasos cada vez que apagues o destruyas producción.

### Ejecución automatizada

[`scripts/sportapp-gcp.ps1`](../scripts/sportapp-gcp.ps1) ejecuta esta guía en orden desde la estación del operador. Solo se completa a mano `platform\.env.ps1`; el script genera `bootstrap.auto.tfvars`, los `gcp.auto.tfvars` y los `backend.hcl` de cada raíz con esos valores y con las salidas del bootstrap. Cada `apply` muestra el plan y pide confirmación. El script no crea llaves, no usa GitHub y no aprueba rollouts.

Desde la carpeta `platform`:

```powershell
Copy-Item .env.example.ps1 .env.ps1   # solo si aún no existe; después complétalo
.\scripts\sportapp-gcp.ps1 check
```

`check` no cambia nada. Informa qué variables faltan o son inválidas, con la línea exacta que debes agregar. También informa el estado de cada archivo de variables (por crear, al día, desactualizado o editado a mano), si el bootstrap ya tiene salidas y si `gcloud` usa la cuenta de `$operator` con credenciales ADC. Con `-Offline` no consulta GCP; con `-Validate` ejecuta además `terraform validate` en cada raíz.

| Comando | Qué hace |
| --- | --- |
| `setup` | Primera preparación completa (secciones 5, 7, 12 y 13): proyectos, facturación, APIs, agentes, bootstrap con respaldo del estado, `production`, secreto JWT, `production-workloads`, `delivery`, primera creación de Cloud Run con los digests de la evidencia y targets. Es idempotente: se detiene con instrucciones en cada paso manual y, al repetirlo, continúa donde quedó. |
| `down` | Destruye solo el plano costoso: GKE con todo lo que corre dentro, Cloud SQL con **todos sus datos y respaldos**, y Cloud Run. Antes comprueba que el plan no alcance otra cosa, retira la base de Kubernetes para liberar los balanceadores internos y guarda los digests desplegados en Cloud Run. Pide escribir el ID del proyecto. |
| `up` | Recrea lo que destruyó `down` y reconcilia `production-workloads` y `delivery`. Al terminar indica cómo volver a promover la última release del backend: su etapa de migraciones recrea los esquemas. |
| `status` | Lista GKE, Cloud SQL, Cloud Run y balanceadores existentes, y el estado de la conexión `github`. |
| `promote` | Ejecuta `promote-release` (`-BackendVersion`, `-FrontendVersion`, `-ReleaseSuffix`). La aprobación sigue siendo humana. |

Los pasos manuales en los que `setup` se detiene son:

1. autorizar la GitHub App (13.3);
2. activar `$releaseTriggersEnabled = $true` cuando backend y frontend tengan `cloudbuild.release.yaml` en `main`;
3. publicar los primeros tags (13.6);
4. cargar `users-jwt-private-key` si `$jwtPrivateKeyFile` no está definido.

| `down` conserva | `down` elimina |
| --- | --- |
| proyectos, facturación, estado, bootstrap e identidades | clúster GKE, nodos y objetos de Kubernetes |
| Artifact Registry con sus imágenes | instancia Cloud SQL, bases, usuarios y contraseñas |
| Secret Manager (incluida la clave JWT), red, Pub/Sub y observabilidad | servicios Cloud Run |
| Cloud Build, Cloud Deploy, conexión GitHub y aprobadores | permisos que dependen de lo anterior; `up` los recrea |

A diferencia de la [sección 15.3](#153-destruir-solamente-el-plano-operativo), `down` no borra Artifact Registry ni los secretos, así que después de `up` no hay que reconstruir imágenes ni volver a cargar la clave JWT. La destrucción completa de `environments/production` sigue siendo el procedimiento manual de esa sección.

Detalles:

- **Archivos generados.** El script respalda en `%USERPROFILE%\terraform-state-backups\sportapp\vars` cualquier archivo editado a mano antes de reemplazarlo. Los cambios se hacen en `.env.ps1`, no en los archivos generados.
- **Imágenes de Cloud Run.** Los digests están en `environments\production\cloud-run-images.auto.tfvars.json`, que también se genera y está ignorado por Git.
- **Política de ejecución.** Si PowerShell bloquea la ejecución de scripts, usa `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` en esa terminal.

Las instrucciones de uso completas están en [`scripts/sportapp-gcp.md`](../scripts/sportapp-gcp.md). Las secciones siguientes siguen siendo la referencia de cada paso y de los controles que el script automatiza.

### Regla de ejecución de los comandos

Las cuatro raíces Terraform son independientes. Un comando `terraform output`, `plan` o `apply` siempre opera sobre la raíz en la que está ubicada la consola; no busca automáticamente el estado de otra raíz.

Antes de cada bloque Terraform, esta guía indica un **Directorio de ejecución**. Ubica primero la consola exactamente en ese directorio y luego ejecuta los comandos sin anteponer la ruta mostrada por el prompt de PowerShell.

| Orden | Directorio de ejecución | Estado que administra | Archivo de variables local |
| --- | --- | --- | --- |
| 1 | `platform\infra\terraform\bootstrap\gcp-state` | estado, identidades y permisos iniciales | `bootstrap.auto.tfvars` |
| 2 | `platform\infra\terraform\environments\production` | infraestructura de producción | `gcp.auto.tfvars` |
| 3 | `platform\infra\terraform\environments\production-workloads` | base Kubernetes de GKE | `gcp.auto.tfvars` |
| 4 | `platform\infra\terraform\environments\delivery` | Cloud Build y Cloud Deploy | `gcp.auto.tfvars` |

No ejecutes `terraform output artifact_registry_urls` desde `delivery`: esa salida pertenece a `production`. Tampoco lo ejecutes antes del primer `apply` exitoso de `production`; antes de ese momento su estado todavía no contiene outputs.

En PowerShell, escribe el `init` exactamente así y sin `\` al final de la línea:

```powershell
terraform init "-backend-config=backend.hcl" -reconfigure
```

### Fase fija: se ejecuta una sola vez y se conserva

1. [Invariantes de seguridad](#1-invariantes-de-seguridad)
2. [Arquitectura objetivo](#2-arquitectura-objetivo)
3. [Prerrequisitos](#3-prerrequisitos)
4. [Definir identificadores](#4-definir-identificadores)
5. [Crear proyectos y autenticarse](#5-crear-proyectos-y-autenticarse)
6. [Adaptar Terraform al modelo sin acceso desde GitHub](#6-adaptar-terraform-al-modelo-sin-acceso-desde-github)
7. [Ejecutar el bootstrap](#7-ejecutar-el-bootstrap)
8. [Preparar los repositorios de componentes](#8-preparar-los-repositorios-de-componentes)
9. [Conectar Cloud Build con GitHub](#9-conectar-cloud-build-con-github)
10. [Configurar construcción y publicación](#10-configurar-construcción-y-publicación)
11. [Configurar Cloud Deploy](#11-configurar-cloud-deploy)

Conserva el proyecto de gestión, los buckets de estado, las identidades, la conexión de Cloud Build y la configuración de Cloud Deploy. En las secciones 9–11 prepara y revisa la configuración, pero no apliques todavía `environments/delivery`: su primer `apply` se realiza en la sección 13, después de aplicar `production` y `production-workloads`. Esta dependencia inicial no se repite mientras se mantenga el plano de gestión.

### Fase operativa: recursos de producción recreables

12. [Crear o recrear la infraestructura de producción](#12-crear-o-recrear-la-infraestructura-de-producción)
13. [Primera release y cierre de la preparación fija](#13-primera-release-y-cierre-de-la-preparación-fija)
14. [Releases posteriores y rollback](#14-releases-posteriores-y-rollback)
15. [Suspender, reanudar, destruir y recrear](#15-suspender-reanudar-destruir-y-recrear)

### Controles y consulta

16. [Archivos y datos sensibles](#16-archivos-y-datos-sensibles)
17. [Verificación de seguridad](#17-verificación-de-seguridad)
18. [Problemas frecuentes](#18-problemas-frecuentes)

| Si vas a... | Ejecuta |
| --- | --- |
| preparar GCP por primera vez | fase fija 1–11, fase operativa 12 y cierre inicial 13 |
| desplegar una nueva versión | sección 14; Terraform no participa si solo cambia código o imagen |
| pausar por poco tiempo | sección 15.1; no deja el costo en cero |
| dejar de usar producción por varios días o semanas | sección 15.3; conserva el plano de gestión |
| volver después de destruir producción | sección 15.4; no repitas 1–11 |

> **Límite de destrucción:** `$mgmt`, el proyecto `$production`, la vinculación de facturación y el estado remoto se conservan. Se destruyen solamente los recursos costosos administrados por la raíz `environments/production`.

Orden exacto de la primera preparación:

1. Ejecuta las secciones 1–8 y prepara los archivos descritos en 9–11 sin aplicar todavía `environments/delivery`.
2. Crea el plano operativo con la sección 12.
3. Completa la conexión, los triggers, los targets y la primera release con la sección 13.
4. En adelante usa únicamente las secciones 14 y 15 para releases y ciclo de vida, salvo que cambie la infraestructura fija.

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
| Ripgrep (opcional) | `rg --version` |
| PowerShell 7 recomendado | `$PSVersionTable.PSVersion` |

Instalación en Windows:

```powershell
winget install --id Hashicorp.Terraform -e
winget install --id Google.CloudSDK -e
winget install --id Git.Git -e
winget install --id Kubernetes.kubectl -e
winget install --id BurntSushi.ripgrep.MSVC -e
```

Ripgrep (`rg`) se usa solamente para búsquedas de texto. Si no está instalado, utiliza `Get-ChildItem` junto con `Select-String`, como muestran los controles que lo requieren; no bloquea Terraform ni los despliegues.

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

Carga el archivo desde la carpeta `platform`, en la misma terminal donde ejecutarás los demás comandos:

```powershell
. .\.env.ps1
```

El comando empieza con **un punto y un espacio** antes de `.\.env.ps1` (*dot-sourcing*). Así el archivo se ejecuta en la sesión actual y sus variables quedan disponibles. Sin ese primer punto (`.\.env.ps1`) el script se ejecuta sin errores, pero sus variables desaparecen al terminar y los comandos siguientes reciben valores vacíos.

Comprueba que se cargaron:

```powershell
Get-Variable mgmt, production, region, operator, billing

if ([string]::IsNullOrWhiteSpace($mgmt))       { throw "Falta cargar `$mgmt" }
if ([string]::IsNullOrWhiteSpace($production)) { throw "Falta cargar `$production" }
if ([string]::IsNullOrWhiteSpace($billing))    { throw "Falta cargar `$billing" }
```

Debe mostrar las cinco variables con sus valores. Si responde `Cannot find a variable with the name ...`, vuelve a cargar el archivo con el punto inicial. Las variables solo existen en esa terminal: si abres otra, cárgalo de nuevo. Si PowerShell indica que la ejecución de scripts está deshabilitada, permítela solo para esa terminal con `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` y repite la carga.

Selecciona el proyecto de gestión como proyecto activo de `gcloud` y comprueba tanto la cuenta como el proyecto antes de ejecutar comandos administrativos:

```powershell
gcloud config set project $mgmt
gcloud auth list --filter=status:ACTIVE --format="value(account)"
gcloud config get-value project
```

El último comando debe mostrar exactamente el valor de `$mgmt`. Aunque los pasos siguientes también incluyen `--project=$mgmt`, esta comprobación evita que un comando incompleto se ejecute accidentalmente contra otro proyecto configurado anteriormente.

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

### 5.3 Habilitar las APIs mínimas para el bootstrap

El primer `terraform plan` consulta ambos proyectos mediante Cloud Resource Manager. Esa consulta ocurre antes de que Terraform pueda administrar `google_project_service`, por lo que estas dos APIs son un prerrequisito manual de arranque y deben habilitarse una sola vez en ambos proyectos:

```powershell
gcloud services enable `
  cloudresourcemanager.googleapis.com `
  serviceusage.googleapis.com `
  --project=$mgmt

gcloud services enable `
  cloudresourcemanager.googleapis.com `
  serviceusage.googleapis.com `
  --project=$production
```

Verifica que quedaron habilitadas:

```powershell
gcloud services list --enabled --project=$mgmt |
  Select-String "cloudresourcemanager|serviceusage"

gcloud services list --enabled --project=$production |
  Select-String "cloudresourcemanager|serviceusage"
```

Si acabas de habilitarlas, espera uno o dos minutos antes de ejecutar Terraform para permitir que el cambio se propague. La identidad usada por `gcloud` debe tener permiso para habilitar servicios en ambos proyectos; durante el arranque normalmente es el usuario que creó los proyectos.

Cuando `delivery = true`, habilita también las APIs de Cloud Build y Cloud Deploy en gestión y crea de forma explícita sus agentes administrados. Habilitar una API no garantiza que su agente ya exista cuando el primer `terraform apply` intente asignarle permisos:

```powershell
if ([string]::IsNullOrWhiteSpace($mgmt)) { throw "Falta cargar `$mgmt; detén el procedimiento" }
gcloud config set project $mgmt

gcloud services enable `
  cloudbuild.googleapis.com `
  clouddeploy.googleapis.com `
  --project=$mgmt

gcloud beta services identity create `
  --service=clouddeploy.googleapis.com `
  --project=$mgmt

gcloud beta services identity create `
  --service=cloudbuild.googleapis.com `
  --project=$mgmt
```

La salida debe mostrar direcciones con el número del proyecto de gestión:

```text
service-PROJECT_NUMBER@gcp-sa-clouddeploy.iam.gserviceaccount.com
service-PROJECT_NUMBER@gcp-sa-cloudbuild.iam.gserviceaccount.com
```

No continúes con Terraform si alguno de los comandos devuelve un error, no muestra la identidad creada o menciona un proyecto distinto de `$mgmt`. Nunca omitas `--project=$mgmt`: el proyecto predeterminado de una instalación anterior de `gcloud` podría ser otro.

Comprueba sus roles en la política del proyecto sin escribir manualmente el número:

```powershell
$mgmtNumber = gcloud projects describe $mgmt --format="value(projectNumber)"
$deployAgent = "serviceAccount:service-$mgmtNumber@gcp-sa-clouddeploy.iam.gserviceaccount.com"
$buildAgent  = "serviceAccount:service-$mgmtNumber@gcp-sa-cloudbuild.iam.gserviceaccount.com"

gcloud projects get-iam-policy $mgmt `
  --flatten="bindings[].members" `
  --filter="bindings.members:$deployAgent" `
  --format="table(bindings.role,bindings.members)"

gcloud projects get-iam-policy $mgmt `
  --flatten="bindings[].members" `
  --filter="bindings.members:$buildAgent" `
  --format="table(bindings.role,bindings.members)"
```

La primera consulta debe mostrar `roles/clouddeploy.serviceAgent` y la segunda `roles/cloudbuild.serviceAgent`. No uses `gcloud iam service-accounts describe` como comprobación de estos agentes administrados: puede responder `iam.serviceAccounts.get denied` aunque Google ya haya creado y resuelto la identidad.

Si la identidad de Cloud Deploy fue creada correctamente pero la primera consulta todavía no muestra su rol después de esperar la propagación, completa exclusivamente el binding del agente administrado:

```powershell
gcloud projects add-iam-policy-binding $mgmt `
  --member=$deployAgent `
  --role="roles/clouddeploy.serviceAgent"
```

No concedas ese rol a usuarios ni a cuentas de servicio creadas por la aplicación; los roles de agente de servicio se asignan únicamente a la identidad administrada correspondiente.

Espera uno o dos minutos después de crearlos antes del primer `terraform apply`.

### 5.4 Políticas de credenciales

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
| `release-promoter` | `logging.logWriter`; `clouddeploy.viewer` (solo lectura) en gestión, para esperar la operación de cada release; lectura de ambos buckets de evidencia y ambos repositorios; `clouddeploy.releaser` en cada pipeline; escritura en el bucket de fuentes; `iam.serviceAccountUser` solo sobre `cloud-deploy-execution` |
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

**Directorio de ejecución:** `platform\infra\terraform\bootstrap\gcp-state`.

Ubica la consola en ese directorio. Después de adaptar el código según la sección 6:

```powershell
if (-not (Test-Path bootstrap.auto.tfvars)) { Copy-Item bootstrap.auto.tfvars.example bootstrap.auto.tfvars }
notepad bootstrap.auto.tfvars
```

En `bootstrap.auto.tfvars`, cada operador debe incluir el tipo de principal IAM. Para una persona utiliza el prefijo `user:`; para un grupo, `group:`. Un correo sin prefijo es inválido.

```hcl
environments = {
  production = {
    project_id           = "sportapp-prod-000000"
    operators            = ["user:operador@example.com"]
    budget_amount        = 300
    budget_alert_amounts = [50, 100, 300]
    delivery             = true
  }
}
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

**Directorio de ejecución:** `platform\infra\terraform\bootstrap\gcp-state`, el directorio que contiene el `main.tf` del bootstrap.

```powershell
terraform init
terraform fmt -check -recursive
terraform validate
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
terraform output
```

### 7.3 Corregir APIs deshabilitadas y operadores inválidos

Si `terraform plan` informa que `operators` es inválido, corrige el valor en `bootstrap.auto.tfvars`. El prefijo forma parte del principal IAM y es obligatorio:

```hcl
operators = ["user:<CORREO_DEL_OPERADOR>"]
```

Si también informa que `cloudresourcemanager.googleapis.com` está deshabilitada, ejecuta el siguiente procedimiento completo en PowerShell. Estas habilitaciones son manuales porque Terraform necesita Cloud Resource Manager antes de poder leer los proyectos y administrar sus APIs:

```powershell
$mgmt       = "<MANAGEMENT_PROJECT_ID>"
$production = "<PRODUCTION_PROJECT_ID>"

gcloud services enable `
  cloudresourcemanager.googleapis.com `
  serviceusage.googleapis.com `
  --project=$mgmt

gcloud services enable `
  cloudresourcemanager.googleapis.com `
  serviceusage.googleapis.com `
  --project=$production
```

Espera uno o dos minutos y verifica:

```powershell
gcloud services list --enabled --project=$mgmt |
  Select-String "cloudresourcemanager|serviceusage"

gcloud services list --enabled --project=$production |
  Select-String "cloudresourcemanager|serviceusage"
```

Después, ubica nuevamente la consola en `platform\infra\terraform\bootstrap\gcp-state` y repite la validación y el plan:

```powershell
terraform validate
terraform plan -out=tfplan
terraform show tfplan
```

Ejecuta `terraform apply tfplan` solamente después de revisar y aprobar el contenido del plan.

Si el `apply` informa que `service-PROJECT_NUMBER@gcp-sa-clouddeploy.iam.gserviceaccount.com` o `service-PROJECT_NUMBER@gcp-sa-cloudbuild.iam.gserviceaccount.com` no existe, no destruyas el estado ni repitas el bootstrap desde cero. Significa que la API quedó habilitada, pero el agente administrado todavía no fue creado en el proyecto de gestión.

Primero confirma que la terminal conserva las variables y que `gcloud` apunta al proyecto correcto:

```powershell
if ([string]::IsNullOrWhiteSpace($mgmt)) { throw "Falta cargar `$mgmt; vuelve a cargar platform\.env.ps1" }
gcloud auth list --filter=status:ACTIVE --format="value(account)"
gcloud config set project $mgmt
gcloud config get-value project
```

Después ejecuta los dos comandos `gcloud beta services identity create` de la sección 5.3. Cada comando debe mostrar la dirección del agente del proyecto de gestión. Si falla o no muestra la identidad, detén el procedimiento y resuelve ese comando antes de volver a ejecutar Terraform.

Verifica los agentes mediante `gcloud projects get-iam-policy`, como indica la sección 5.3. Un resultado `iam.serviceAccounts.get denied` obtenido con `gcloud iam service-accounts describe` no implica por sí solo que el agente no exista y no debe resolverse otorgando permisos adicionales al usuario. Si falta `roles/clouddeploy.serviceAgent`, aplica únicamente el binding documentado en la sección 5.3.

Cuando ambas identidades existan, espera la propagación y genera un plan nuevo con otro nombre:

```powershell
terraform validate
terraform plan -out=tfplan-retry
terraform show tfplan-retry
terraform apply tfplan-retry
terraform output
```

No reutilices el plan anterior después de un `apply` fallido: Terraform pudo haber guardado APIs, buckets u otros recursos creados correctamente antes del error.

No es necesario repetir `terraform init` para este reintento, salvo que hayan cambiado el backend, los providers o la configuración de módulos.

Los valores de `budget_alert_amounts` son montos absolutos en la moneda configurada. Todos deben ser mayores que cero y menores o iguales a `budget_amount`; por ejemplo, `[50, 100, 300]` es válido para un presupuesto de `300`. Los presupuestos generan alertas, pero no detienen automáticamente el consumo.

### 7.4 Revisar el plan antes de aplicarlo

No revises únicamente el resumen numérico. Ejecuta primero el siguiente bloque completo y conserva la misma terminal para los controles posteriores. Las variables `$planFile`, `$planText`, `$planJson`, `$plan` y `$changes` se crean en este bloque y no existen automáticamente en una terminal nueva.

Lista los planes disponibles y asigna a `$planFile` el nombre exacto del plan que acabas de generar; no selecciones un plan antiguo:

```powershell
Get-ChildItem -File tfplan*

$planFile = "tfplan" # Cambia este valor, por ejemplo, a "tfplan-retry"
if (-not (Test-Path -LiteralPath $planFile -PathType Leaf)) {
  throw "No existe el plan '$planFile'. Revisa Get-ChildItem -File tfplan*"
}

$planText = Join-Path $env:TEMP "sportapp-bootstrap-plan.txt"
$planJson = Join-Path $env:TEMP "sportapp-bootstrap-plan.json"

terraform show -no-color $planFile | Set-Content -Encoding utf8 $planText
terraform show -json $planFile | Set-Content -Encoding utf8 $planJson

$plan = Get-Content -Raw $planJson | ConvertFrom-Json
$changes = @($plan.resource_changes)
$changes |
  Select-Object address, @{Name="actions"; Expression={ $_.change.actions -join "," }} |
  Sort-Object address |
  Format-Table -AutoSize
```

Comprueba cada control:

1. **WIF/OIDC anterior.** En una instalación nueva el resultado debe estar vacío. En una migración solo se permiten acciones `delete` o `forget`; nunca `create`, `update` o `replace`:

   ```powershell
   $changes |
     Where-Object {
       $_.address -match "workload_identity|oidc|plan_github|apply_github|delivery_github|ci_delivery"
     } |
     Select-Object address, @{Name="actions"; Expression={ $_.change.actions -join "," }}
   ```

2. **Llaves persistentes.** El resultado debe estar vacío. El bootstrap crea cuentas, pero nunca recursos `google_service_account_key`:

   ```powershell
   $changes |
     Where-Object { $_.type -eq "google_service_account_key" } |
     Select-Object address, @{Name="actions"; Expression={ $_.change.actions -join "," }}
   ```

3. **Impersonación de `tf-apply-production`.** Revisa el bloque `google_service_account_iam_policy.apply["production"]`. Debe contener solamente `roles/iam.serviceAccountTokenCreator` y los `user:` o `group:` declarados en `operators`. Este comando usa directamente el plan y no depende de `$planText`:

   ```powershell
   if ([string]::IsNullOrWhiteSpace($planFile) -or -not (Test-Path -LiteralPath $planFile)) {
     throw "Define `$planFile con el nombre del plan existente antes de continuar"
   }

   terraform show -no-color $planFile | Select-String `
     -Pattern "google_service_account_iam_policy.apply", "roles/iam.serviceAccountTokenCreator", "user:", "group:" `
     -Context 3,8
   ```

   Rechaza el plan si esa política incluye GitHub, `principalSet`, `allUsers`, Cloud Build, Cloud Deploy o alguna cuenta de servicio.

4. **Identidades separadas.** Deben aparecer, como `create` o `no-op`, las cuatro cuentas y no una identidad compartida:

   ```powershell
   $changes |
     Where-Object { $_.address -match '^google_service_account.delivery' } |
     Select-Object address, @{Name="actions"; Expression={ $_.change.actions -join "," }}
   ```

   Los nombres esperados son `cloud-build-backend`, `cloud-build-frontend`, `release-promoter` y `cloud-deploy-execution`.

5. **Presupuesto y estado.** Deben aparecer como `create` o `no-op` estos recursos:

   ```powershell
   $changes |
     Where-Object {
       $_.address -match '^google_billing_budget.environment' -or
       $_.address -match '^google_storage_bucket.state'
     } |
     Select-Object address, @{Name="actions"; Expression={ $_.change.actions -join "," }}
   ```

6. **Destrucciones inesperadas.** Fuera de los recursos WIF/OIDC antiguos durante una migración, esta consulta debe quedar vacía:

   ```powershell
   $changes |
     Where-Object {
       $_.change.actions -contains "delete" -and
       $_.address -notmatch "workload_identity|oidc|plan_github|apply_github|delivery_github|ci_delivery"
     } |
     Select-Object address, @{Name="actions"; Expression={ $_.change.actions -join "," }}
   ```

Si algún resultado no coincide con lo esperado, no ejecutes `terraform apply`. Corrige la configuración y genera un plan nuevo; nunca modifiques un plan guardado.

### 7.5 Respaldar el estado local del bootstrap

El estado puede contener información sensible. Guárdalo fuera del repositorio y no lo subas a Git. Después de un `apply` exitoso —o antes de continuar tras un `apply` parcial— crea un respaldo y su checksum:

```powershell
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $env:USERPROFILE "terraform-state-backups\sportapp"
$backupFile = Join-Path $backupDir "bootstrap-$stamp.tfstate"

New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
terraform state pull | Set-Content -Encoding utf8 $backupFile
Get-Item $backupFile
Get-FileHash -Algorithm SHA256 $backupFile
```

Confirma que el archivo existe, tiene tamaño mayor que cero y conserva el hash. No copies este respaldo dentro de `platform` ni lo envíes por correo o mensajería.

### 7.6 Migrar el estado al bucket de gestión

Realiza esta migración únicamente después de que el bootstrap termine correctamente y `terraform output state_buckets` muestre el bucket. Primero conserva el respaldo de la sección 7.5.

Obtén el nombre exacto del bucket:

```powershell
$stateBuckets = terraform output -json state_buckets | ConvertFrom-Json
$stateBucket = $stateBuckets.production
if ([string]::IsNullOrWhiteSpace($stateBucket)) { throw "No se encontró el bucket de estado de production" }
$stateBucket
```

En `versions.tf`, descomenta solamente el backend:

```hcl
backend "gcs" {
  prefix = "sportapp/bootstrap"
}
```

No escribas credenciales ni el nombre del bucket en `versions.tf`. Ejecuta la migración pasando el bucket como configuración local:

```powershell
terraform init -migrate-state -backend-config="bucket=$stateBucket"
```

Terraform preguntará si debe copiar el estado existente al backend GCS; revisa el nombre del bucket y responde `yes`. Después verifica el estado remoto:

```powershell
terraform state list
gcloud storage ls "gs://$stateBucket/sportapp/bootstrap/"
terraform plan -out=tfplan-post-migration
terraform show tfplan-post-migration
```

El plan posterior a la migración no debe recrear los recursos del bootstrap. Conserva el respaldo local de la sección 7.5; no borres ni muevas manualmente objetos dentro del bucket de estado.

## 8. Preparar los repositorios de componentes

Backend y frontend deben implementar el siguiente contrato.

### 8.1 GitHub Actions

- CI de push/PR y validación de release.
- `permissions: contents: read` como base.
- sin `id-token: write`.
- sin `google-github-actions/auth`.
- sin `gcloud`, `kubectl`, Terraform o push a Artifact Registry.
- sin secrets o variables GCP.

Comprueba los workflows desde la raíz de cada repositorio, no desde `platform\infra\terraform\bootstrap\gcp-state`. Evita construir las rutas a partir de `git rev-parse` en Windows PowerShell antiguo: una ruta con tildes puede decodificarse incorrectamente y producir nombres como `Mestr├¡a`.

En una terminal ubicada en la raíz de `backend`:

```powershell
Get-ChildItem .github\workflows -File -Recurse | Select-String -Pattern "google-github-actions/auth|id-token: write|GCP_|gcloud|kubectl|terraform"
```

Después cambia al repositorio hermano y repite en `frontend`:

```powershell
Set-Location ..\frontend
Get-ChildItem .github\workflows -File -Recurse | Select-String -Pattern "google-github-actions/auth|id-token: write|GCP_|gcloud|kubectl|terraform"
```

En cada repositorio el resultado debe estar vacío o limitarse a comentarios que expliquen la prohibición. Si la terminal ya está en `frontend`, ejecuta solamente el segundo `Get-ChildItem`; no vuelvas a cambiar de directorio.

Si Ripgrep está instalado, el comando equivalente y opcional desde la raíz de cada repositorio es:

```powershell
rg -n "google-github-actions/auth|id-token: write|GCP_|gcloud|kubectl|terraform" .github/workflows
```

### 8.2 Configuración Cloud Build

Cada repositorio conserva un archivo `cloudbuild.release.yaml` que:

1. valida la versión;
2. ejecuta pruebas completas;
3. construye una sola vez;
4. publica imágenes por versión y commit;
5. resuelve los digests;
6. produce `backend-release.json` o `frontend-release.json`;
7. no despliega y no modifica infraestructura.

#### Cuándo se ejecuta

`cloudbuild.release.yaml` es un pipeline de **release**, no el pipeline de integración continua de cada cambio. Los triggers `release-backend` y `release-frontend` observan eventos de tags en sus respectivos repositorios y solo arrancan cuando se envía a GitHub un tag que coincide con SemVer: `vX.Y.Z` o `vX.Y.Z-pre`.

| Evento en backend o frontend | ¿Ejecuta este Cloud Build? | Motivo |
| --- | --- | --- |
| push a una rama de trabajo | no | el trigger no observa pushes de ramas |
| abrir o actualizar un pull request hacia `main` | no | las validaciones del PR pertenecen a GitHub Actions y no tienen acceso a GCP |
| merge del pull request en `main` | no | el merge es un push de rama, no un tag de release |
| crear y enviar `v1.2.0` apuntando a un commit de `main` | sí | el push del tag coincide con el patrón del trigger |
| crear un tag como `prueba`, `latest` o `release-1` | no | no coincide con el patrón SemVer configurado |
| ejecutar `promote-release` | no vuelve a construir | es un proceso manual posterior que consume la evidencia y prepara Cloud Deploy |

El orden operativo es:

```text
PR -> validaciones en GitHub -> merge en main -> tag SemVer vX.Y.Z -> Cloud Build de release
```

Un tag no pertenece formalmente a una rama: apunta a un commit. Por eso la regla correcta es que **el commit etiquetado debe ser ancestro de `main`**. Crear una GitHub Release solo dispara este flujo si al hacerlo se crea y envía un tag nuevo; publicar una Release sobre un tag que ya existía no genera otro push del tag.

Estado de la validación de origen:

- backend: el paso `verify` comprueba que el tag apunta al commit recibido y que ese commit pertenece a `main`; si no, el build falla antes de publicar;
- frontend: el paso `validate` comprueba SemVer, SHA y repositorio, pero actualmente no comprueba la pertenencia del commit a `main`. Hasta incorporar esa comprobación, el tag debe crearse operativamente desde un commit ya integrado en `main`; el trigger por sí solo también arrancaría para un tag SemVer creado desde otra rama.

Ubicación exacta:

- backend: [`backend/cloudbuild.release.yaml`](../../backend/cloudbuild.release.yaml); la implementación está en [`backend/scripts/release.py`](../../backend/scripts/release.py);
- frontend: [`frontend/cloudbuild.release.yaml`](../../frontend/cloudbuild.release.yaml); cada etapa llama a [`frontend/deploy/release/cloudbuild-release.sh`](../../frontend/deploy/release/cloudbuild-release.sh) y el manifiesto se genera con [`release-manifest.mjs`](../../frontend/deploy/release/release-manifest.mjs).

Correspondencia entre el requisito y los pasos reales:

| Requisito | Backend | Frontend |
| --- | --- | --- |
| validar versión, tag, commit y origen | paso `verify` de `cloudbuild.release.yaml` (aprox. líneas 46–65), que ejecuta `scripts/release.py verify` y comprueba la pertenencia a `main` | paso `validate` (aprox. líneas 56–59), que llama la etapa `validate` de `cloudbuild-release.sh` (aprox. líneas 48–64); todavía no comprueba la pertenencia a `main` |
| ejecutar controles y pruebas completas | pasos `quality` y `tests` (aprox. líneas 103–137): formato, lint, tipos, seguridad, unitarias, integración, contrato, componente y cobertura | pasos `checks`, `unit-tests`, `audit` y `smoke`; su lógica está en `cloudbuild-release.sh` (aprox. líneas 70–107) |
| construir una sola vez | paso `images` (aprox. líneas 166–180), que genera el plan y construye cada componente una vez | paso `image` y etapa `image` del script (aprox. líneas 93–101); guarda el ID y los pasos posteriores verifican que sea la misma imagen |
| publicar por versión y commit | paso `push` (aprox. líneas 182–186), usando el plan creado por `images` | paso `publish`; ejecuta dos `docker push` sobre la misma imagen, uno con tag de versión y otro con commit (aprox. líneas 114–120 del script) |
| resolver digests inmutables | el mismo paso `push` escribe `dist/image-digests.json` | la etapa `publish` lee `RepoDigests`, exige exactamente un `@sha256` y escribe `dist/image-uri.txt` (aprox. líneas 120–125) |
| producir y almacenar evidencia | paso `manifest` crea `dist/backend-release.json` y `artifacts.objects` lo guarda en el bucket (aprox. líneas 188–212) | pasos `manifest` y `store` crean y suben `dist/frontend-release.json` (aprox. líneas 109–117 del YAML y 128–143 del script) |
| no desplegar ni modificar infraestructura | la lista de pasos termina al generar/publicar evidencia; no contiene `terraform`, `kubectl`, `gcloud run` ni creación de releases de Cloud Deploy | la lista termina en `store`; `gcloud storage cp` solo guarda la evidencia y no existe una etapa de despliegue |

Los números de línea son referencias de lectura y pueden moverse con futuras ediciones; los identificadores `id` y los nombres de etapa son la referencia estable. Estos archivos construyen y publican, pero no se ejecutan manualmente desde la estación: los usa Cloud Build cuando GitHub informa el push de un tag SemVer que coincide con el patrón del trigger.

La identidad no se declara ni se almacena en el repositorio: la asigna el trigger creado por Terraform. Las sustituciones que envía cada trigger son exactamente las que declara su archivo:

| Trigger | Sustituciones | Evidencia |
| --- | --- | --- |
| `release-backend` | `_AR_LOCATION`, `_AR_PROJECT`, `_AR_REPOSITORY=sportapp-backend`, `_RELEASE_BUCKET` | `gs://<bucket backend>/sport-app-backend/<tag>/backend-release.json` |
| `release-frontend` | `_REGISTRY`, `_REPOSITORY=sportapp-frontend`, `_RELEASE_BUCKET` | `gs://<bucket frontend>/frontend/<tag>/frontend-release.json` |

Formatos aceptados: [`schemas/backend-release.schema.json`](../schemas/backend-release.schema.json) y [`schemas/frontend-release.schema.json`](../schemas/frontend-release.schema.json).

### 8.3 Manifiesto de salida

El promotor acepta únicamente manifiestos que incluyan:

- repositorio y commit;
- tag SemVer;
- identificador de Cloud Build exitoso;
- contrato esperado;
- imágenes `Artifact Registry@sha256`;
- resultados de pruebas y checksums;
- ninguna referencia `latest`.

## 9. Conectar Cloud Build con GitHub

Este procedimiento se realiza desde GCP una sola vez, declarado por Terraform y aplicado por el operador. Durante la fase fija prepara `environments/delivery` y sus variables, pero ejecuta su primer `apply` en la sección 13, después de crear el estado y los recursos de producción que consulta esta raíz.

> **No apliques `environments/delivery` mientras recorres esta sección.** Las secciones 9 a 11 describen y preparan el plano de entrega. El orden ejecutable es: bootstrap (sección 7) → `environments/production` (12.3) → `production-workloads` (12.4) → primer apply de `environments/delivery` (sección 13). Si producción no fue aplicada, `delivery` recibe un objeto de outputs vacío y falla con `local.production is object with no attributes`.

### 9.1 Instalar la conexión

La conexión necesita **dos aplicaciones consecutivas de la misma raíz Terraform**, con una autorización manual entre ellas. No son dos infraestructuras distintas.

| Momento | `github_connection_ready` | `release_triggers_enabled` | Resultado |
| --- | --- | --- | --- |
| primer apply | `false` | `false` | respecto a GitHub, crea únicamente la conexión `github`, todavía pendiente de autorización; no vincula repositorios ni crea triggers |
| segundo apply, después de autorizar | `true` | `false` | vincula los tres repositorios y crea los triggers de release deshabilitados; todavía ningún tag puede iniciar un build |
| activación final | `true` | `true` | habilita `release-backend` y `release-frontend` para tags SemVer |

En esta sección se preparan los archivos locales. **No ejecutes todavía `terraform init`, `plan` ni `apply` en `delivery`; esos comandos están, una sola vez y en el orden correcto, en la sección 13.**

1. **Directorio de ejecución:** `platform\infra\terraform\bootstrap\gcp-state`.

   El bootstrap ya debe tener un `apply` exitoso. Obtén de su estado los valores que usarán las otras raíces:

   ```powershell
   $applyAccounts = terraform output -json apply_service_accounts | ConvertFrom-Json
   $stateBuckets = terraform output -json state_buckets | ConvertFrom-Json
   $deliveryIdentities = terraform output -json delivery_identities | ConvertFrom-Json

   $applyAccounts.production
   $stateBuckets.production
   $deliveryIdentities
   ```

   Si alguno está vacío, detente: el bootstrap no terminó correctamente. Estos comandos leen el estado del bootstrap; no leen ningún `gcp.auto.tfvars`.

2. **Directorio de ejecución:** `platform\infra\terraform\environments\delivery`.

   Crea los dos archivos locales a partir de sus ejemplos y ábrelos:

   ```powershell
   if (-not (Test-Path gcp.auto.tfvars)) { Copy-Item gcp.auto.tfvars.example gcp.auto.tfvars }
   if (-not (Test-Path backend.hcl)) { Copy-Item backend.hcl.example backend.hcl }
   notepad gcp.auto.tfvars
   notepad backend.hcl
   ```

   Terraform no carga los archivos `.example`. Los archivos reales están ignorados por Git y no deben publicarse.

3. Completa `gcp.auto.tfvars` usando exactamente estas fuentes:

   | Variable | Valor que debes colocar | Fuente exacta |
   | --- | --- | --- |
   | `management_project_id` | ID del proyecto de gestión | valor `$mgmt` definido en la sección 4 |
   | `impersonate_service_account` | correo completo de `tf-apply-production` | `$applyAccounts.production` obtenido en el paso 1 |
   | `state_bucket` | bucket de estado de producción | `$stateBuckets.production` obtenido en el paso 1 |
   | `delivery_identities.build_backend` | cuenta de build del backend | `$deliveryIdentities.build_backend` |
   | `delivery_identities.build_frontend` | cuenta de build del frontend | `$deliveryIdentities.build_frontend` |
   | `delivery_identities.release_promoter` | cuenta promotora | `$deliveryIdentities.release_promoter` |
   | `delivery_identities.deploy_execution` | cuenta de ejecución | `$deliveryIdentities.deploy_execution` |
   | `approvers` | persona o grupo que aprobará rollouts | decisión administrativa en formato `user:<correo>` o `group:<correo>` |
   | `deploy_tools_image` | imagen de herramientas fijada por digest | imagen aprobada que incluya `gcloud`, `kubectl` y `gke-gcloud-auth-plugin` |
   | `github_connection_ready` | `false` | valor inicial obligatorio |
   | `release_triggers_enabled` | `false` | valor inicial obligatorio |

   La forma final es:

   ```hcl
   management_project_id       = "<MANAGEMENT_PROJECT_ID>"
   impersonate_service_account = "<APPLY_SERVICE_ACCOUNT_PRODUCTION>"
   state_bucket                = "<STATE_BUCKET_PRODUCTION>"

   delivery_identities = {
     build_backend    = "<DELIVERY_IDENTITY_BUILD_BACKEND>"
     build_frontend   = "<DELIVERY_IDENTITY_BUILD_FRONTEND>"
     release_promoter = "<DELIVERY_IDENTITY_RELEASE_PROMOTER>"
     deploy_execution = "<DELIVERY_IDENTITY_DEPLOY_EXECUTION>"
   }

   approvers = ["user:<CORREO_APROBADOR>"]
   deploy_tools_image = "<REGISTRO>/<IMAGEN>:<VERSION>@sha256:<DIGEST_APROBADO>"

   github_connection_ready  = false
   release_triggers_enabled = false
   ```

4. Completa `backend.hcl` con los mismos valores del bootstrap:

   ```hcl
   bucket                      = "<STATE_BUCKET_PRODUCTION>"
   impersonate_service_account = "<APPLY_SERVICE_ACCOUNT_PRODUCTION>"
   ```

5. Para obtener `deploy_tools_image`, selecciona una versión fija de la imagen completa de Google Cloud CLI y consulta su digest:

   ```powershell
   $toolsTag = "gcr.io/google.com/cloudsdktool/google-cloud-cli:<VERSION>"
   docker buildx imagetools inspect $toolsTag
   ```

   La referencia guardada debe terminar en `@sha256:<64 caracteres hexadecimales>` y no puede usar `latest`.

6. **Detente aquí.** Continúa con las secciones 10, 11 y 12. La creación y autorización de la conexión se ejecuta en la sección 13, cuando el estado de producción ya contiene los outputs que `delivery` necesita.

No agregues secretos GCP en GitHub. Terraform no reconcilia `github_config` de la conexión porque esa configuración la escribe el proceso de autorización de Cloud Build.

### 9.2 Crear triggers

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

### 9.3 Probar sin publicar una release productiva

Usa un tag de prueba en un repositorio o fork no productivo y confirma:

- el build puede leer código;
- solo escribe en su repositorio de Artifact Registry;
- no puede listar secretos ni modificar Cloud Run/GKE;
- no puede impersonar `tf-apply-production`;
- produce el manifiesto de salida esperado.

Elimina los artefactos de prueba después de verificar la política de retención.

## 10. Configurar construcción y publicación

### 10.1 Artifact Registry

Usa repositorios separados o permisos separados por prefijo para backend y frontend. Las cuentas de construcción reciben solo escritura en el destino que les corresponde. Las identidades de ejecución reciben solo lectura.

Configura:

- tags inmutables;
- limpieza de imágenes no etiquetadas;
- conservación de releases recientes;
- análisis de vulnerabilidades;
- alertas ante builds o pushes fallidos.

### 10.2 Separación de build y promoción

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

## 11. Configurar Cloud Deploy

### 11.1 Pipelines y targets

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

### 11.2 Configuración controlada por la plataforma

Guarda en `sport-app-platform`:

- definición de pipelines y targets;
- configuración Skaffold;
- plantillas Cloud Run;
- overlay productivo GKE;
- mapeo entre imágenes y Deployments;
- verificaciones y procedimientos de rollback.

Está en [`deploy/clouddeploy`](../deploy/clouddeploy): [`allowlist.json`](../deploy/clouddeploy/allowlist.json) (componentes, pipelines, imágenes y objetos Kubernetes permitidos), `gke/skaffold.yaml` con los perfiles `migrations` y `workloads`, los overlays de Kustomize y `cloudrun/<servicio>/` con `service.yaml` y su smoke. Los manifiestos del componente pueden definir su contrato técnico, pero el promotor solo acepta campos e imágenes de la allowlist y ninguna verificación ni hook proviene de la release del componente.

Las verificaciones de GKE usan `deploy_tools_image` (gcloud, kubectl y `gke-gcloud-auth-plugin`, por digest; variable obligatoria de `environments/delivery`) y las de Cloud Run, `run_verify_image` (gcloud y curl).

### 11.3 Cuenta de ejecución

`cloud-deploy-execution` debe poder:

- leer imágenes aprobadas;
- actualizar los servicios Cloud Run permitidos;
- operar únicamente en el namespace productivo de GKE;
- consultar rollouts y logs necesarios.

En GKE combina IAM con Kubernetes RBAC. No uses `cluster-admin`.

### 11.4 Aprobadores

`approvers` (en `environments/delivery`) recibe `roles/clouddeploy.approver` en cada pipeline y solo admite `user:` o `group:`. No se asigna a:

- Cloud Build;
- `release-promoter`;
- `cloud-deploy-execution`;
- cuentas de los workloads.

### 11.5 Binary Authorization

Deshabilitada por defecto (`binary_authorization = { enabled = false }` en `environments/production`). Al habilitarla con al menos un attestor, Terraform crea la política del proyecto (`REQUIRE_ATTESTATION`, siempre por digest) y la aplica en GKE y Cloud Run. El permiso para cambiar la política queda en `tf-apply-production` (`binaryauthorization.policyEditor`); las cuentas de entrega no reciben ningún rol de Binary Authorization. Habilítala solo cuando el build produzca attestations válidas.

## 12. Crear o recrear la infraestructura de producción

Esta sección administra el plano operativo que puede destruirse y volver a crearse. No crea nuevamente los proyectos, la facturación, el bootstrap, las identidades ni la conexión con GitHub.

### 12.1 Archivos locales

La primera vez crea los archivos locales ignorados por Git. Después de una destrucción reutilízalos; no vuelvas a copiarlos si ya contienen los valores aprobados.

**Directorio de ejecución:** `platform\infra\terraform\environments\production`.

```powershell
if (-not (Test-Path gcp.auto.tfvars)) { Copy-Item gcp.auto.tfvars.example gcp.auto.tfvars }
if (-not (Test-Path backend.hcl)) { Copy-Item backend.hcl.example backend.hcl }
notepad gcp.auto.tfvars
notepad backend.hcl
```

Terraform no utiliza los archivos `.example`; debes completar los dos archivos reales antes de ejecutar `init` o `plan`.

| Campo | Valor que debes colocar | Fuente exacta |
| --- | --- | --- |
| `project_id` | ID del proyecto de producción | `$production` de la sección 4 |
| `impersonate_service_account` | correo completo de `tf-apply-production` | `apply_service_accounts.production` del bootstrap |
| `delivery_identities` | las cuatro cuentas de entrega | salida completa `delivery_identities` del bootstrap |
| `health_data_consent_version` | versión aprobada del consentimiento | decisión funcional aprobada; el plan se detiene si se deja comentada o vacía |
| `alert_emails` | destinatarios reales de alertas | personas o grupos operativos definidos para producción |
| `gke_authorized_networks` | CIDR público del operador, si se usará el endpoint IP | opcional; déjalo como lista vacía si se usará el endpoint DNS |
| `bucket` en `backend.hcl` | bucket de estado de producción | `state_buckets.production` del bootstrap |
| `impersonate_service_account` en `backend.hcl` | la misma cuenta de aplicación | `apply_service_accounts.production` del bootstrap |

En `gcp.auto.tfvars`, descomenta y reemplaza obligatoriamente `health_data_consent_version`; no dejes `sportapp-prod-000000`, `sportapp-mgmt-000000`, `example.com` ni marcadores `<...>`.

Para la primera aplicación conserva `cloud_run_images = {}` en el archivo versionado `terraform.tfvars`. Cloud Run se crea después de que Cloud Build publique los primeros digests.

`backend.hcl` debe tener esta forma:

```hcl
bucket                      = "<STATE_BUCKET_PRODUCTION>"
impersonate_service_account = "<APPLY_SERVICE_ACCOUNT_PRODUCTION>"
```

Los archivos `gcp.auto.tfvars` y `backend.hcl` permanecen fuera de Git.

### 12.2 Verificar autenticación e impersonación

**Directorio de ejecución para cargar `.env.ps1`:** raíz `platform`.

Después de abrir una terminal nueva, carga los identificadores y renueva ADC si fuera necesario:

```powershell
. .\.env.ps1
gcloud auth application-default login
$tfApply = "tf-apply-production@$mgmt.iam.gserviceaccount.com"
gcloud auth print-access-token --impersonate-service-account=$tfApply
```

Un `403` indica que el operador no tiene `roles/iam.serviceAccountTokenCreator` sobre esa cuenta concreta. No repitas `gcloud auth application-default login` mientras las credenciales sigan vigentes.

### 12.3 Crear la infraestructura base

**Directorio de ejecución:** `platform\infra\terraform\environments\production`.

Confirma que `gcp.auto.tfvars` y `backend.hcl` ya existen en este directorio. Luego ejecuta:

```powershell
terraform init "-backend-config=backend.hcl" -reconfigure
terraform validate
terraform test
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
```

Solo después de que `terraform apply tfplan` termine correctamente, comprueba las salidas de **esta misma raíz**:

```powershell
terraform output artifact_registry_urls
terraform output delivery_identities
terraform output gke
terraform output app_secret_ids
```

Si `terraform output` exige inicializar el backend, todavía falta ejecutar el `init` anterior. Si responde `No outputs found`, `production` aún no tiene un `apply` exitoso en ese backend; no continúes con `production-workloads` ni con `delivery`.

La primera aplicación deja Cloud Run sin servicios porque todavía no existen imágenes aprobadas. No uses imágenes públicas o tags mutables como marcador. Primero construye la release inicial y luego realiza la creación controlada descrita en la sección 13.

Antes de aplicar `production-workloads`, cada secreto de aplicación listado por `terraform output app_secret_ids` debe tener al menos una versión habilitada. Para `users-jwt-private-key`, carga la clave privada Ed25519 aprobada desde un archivo temporal seguro; no pegues el valor en Terraform ni en Git:

```powershell
$jwtPrivateKeyFile = "C:\ruta-segura\sportapp-users-jwt.pem" # reemplaza esta ruta local
gcloud secrets versions add users-jwt-private-key --data-file=$jwtPrivateKeyFile --project=$production
gcloud secrets versions list users-jwt-private-key --project=$production
```

### 12.4 Crear o reconciliar la base de GKE

La raíz `production-workloads` solo debe aplicarse después de completar la separación de propiedad de la sección 6.4, el `apply` exitoso de `production` y la carga de las versiones de secretos requeridas. Tras recrear el clúster, este `apply` detecta y vuelve a crear los objetos que desaparecieron con el GKE anterior.

Antes de continuar, confirma que el submódulo `platform\components\backend` está descargado y contiene `deploy\k8s\base`. Si falta, inicialízalo desde la raíz `platform`:

```powershell
git -c core.longpaths=true submodule update --init --checkout components/backend
```

`--checkout` es necesario porque `.gitmodules` declara `update = none`; sin él, el comando no descarga nada. `core.longpaths` evita el error `Filename too long` de Windows en las migraciones del backend.

El submódulo debe apuntar a un commit que tenga `deploy/k8s/base`: el tag publicado del backend o, antes de la primera release, `develop`. El *first commit* no lo tiene. Para moverlo:

```powershell
git -C components/backend fetch origin
git -C components/backend checkout --detach origin/develop   # o el tag, por ejemplo v0.1.0
```

Confirma el cambio del submódulo en la plataforma, porque los Services que crea esta raíz salen de ese commit.

**Directorio de ejecución:** `platform\infra\terraform\environments\production-workloads`.

```powershell
if (-not (Test-Path gcp.auto.tfvars)) { Copy-Item gcp.auto.tfvars.example gcp.auto.tfvars }
if (-not (Test-Path backend.hcl)) { Copy-Item backend.hcl.example backend.hcl }
notepad gcp.auto.tfvars
notepad backend.hcl
```

Completa los archivos antes del `init`:

| Campo | Valor que debes colocar | Fuente exacta |
| --- | --- | --- |
| `project_id` | ID de producción | `$production` |
| `state_bucket` | bucket de estado de producción | `state_buckets.production` del bootstrap |
| `impersonate_service_account` | cuenta de aplicación | `apply_service_accounts.production` del bootstrap |
| `bucket` en `backend.hcl` | el mismo bucket | `state_buckets.production` del bootstrap |
| `impersonate_service_account` en `backend.hcl` | la misma cuenta de aplicación | `apply_service_accounts.production` del bootstrap |

Luego, desde el mismo directorio:

```powershell
terraform init "-backend-config=backend.hcl" -reconfigure
terraform validate
terraform test
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
terraform output
```

El plan no debe incluir Deployments ni Jobs, porque los administra Cloud Deploy.

### 12.5 Qué se crea y puede destruirse

| Raíz | Recursos operativos |
| --- | --- |
| `environments/production` | VPC, GKE, Cloud SQL, Pub/Sub, Artifact Registry, Secret Manager, Cloud Run, observabilidad y permisos cruzados |
| `environments/production-workloads` | namespace, Services, ConfigMap, KSA, RBAC y Secrets dentro del clúster |

La raíz `production-workloads` conserva su estado en el bucket de gestión. Al destruir GKE, sus objetos desaparecen físicamente; después de recrear el clúster, ejecuta nuevamente la sección 12.4 para reconciliarlos.

## 13. Primera release y cierre de la preparación fija

La primera release resuelve la dependencia entre infraestructura e imágenes: Cloud Run necesita un digest para crear su primera revisión y Cloud Deploy necesita servicios y targets existentes. Todos los `apply` se hacen desde la estación del operador con un plan guardado y revisado.

### 13.1 Confirmar los prerrequisitos de producción

Antes de tocar `delivery`, deben haber terminado correctamente las secciones 7, 12.3 y 12.4.

**Directorio de ejecución:** `platform\infra\terraform\environments\production`.

```powershell
terraform output artifact_registry_urls
terraform output delivery_identities
terraform output gke
```

Los tres comandos deben devolver objetos con valores. Si Terraform solicita `init`, ejecuta primero `terraform init "-backend-config=backend.hcl" -reconfigure` en este mismo directorio. Si muestra `No outputs found`, detente: `production` todavía no fue aplicada correctamente y `delivery` fallará con `local.production is object with no attributes`.

### 13.2 Crear la conexión de GitHub

**Directorio de ejecución:** `platform\infra\terraform\environments\delivery`.

Confirma que los archivos preparados en la sección 9 existen en este directorio y que las dos banderas tienen estos valores:

```hcl
github_connection_ready  = false
release_triggers_enabled = false
```

Terraform no puede crear la conexión pendiente: la API de Cloud Build exige `github_config` y el provider omite el bloque vacío, de modo que solo podría crearla con un PAT de GitHub, que este modelo no usa. Créala con `gcloud`, sin PAT, e impórtala. `sportapp-gcp.ps1` hace ambos pasos solo.

```powershell
gcloud builds connections create github github --region=$region --project=$mgmt
terraform init "-backend-config=backend.hcl" -reconfigure
terraform import google_cloudbuildv2_connection.github "projects/$mgmt/locations/$region/connections/github"
```

Después ejecuta el primer apply de `delivery`:

```powershell
terraform validate
terraform test
terraform plan -out=tfplan-connection
terraform show tfplan-connection
terraform apply tfplan-connection
```

Respecto a GitHub, este primer apply solo concede a las cuentas de build y al promotor la lectura de la conexión, que sigue pendiente de autorización. No crea todavía los repositorios vinculados ni habilita triggers. El agente de Cloud Build recibe en el bootstrap `roles/secretmanager.admin` en gestión, porque al autorizar guarda allí el token OAuth de la conexión.

### 13.3 Autorizar la GitHub App una sola vez

1. En el proyecto de gestión de la consola de GCP abre **Cloud Build → Repositorios (2.ª gen.)**.
2. Selecciona la región configurada y la conexión `github`.
3. Pulsa **Terminar la configuración** e inicia sesión con una cuenta que pueda instalar aplicaciones en la cuenta u organización de GitHub.
4. Elige **solo repositorios seleccionados** y autoriza exclusivamente `sport-app-backend`, `sport-app-frontend` y `sport-app-platform`.
5. Comprueba desde PowerShell que la conexión quedó completa; este comando puede ejecutarse desde cualquier directorio si `$region` y `$mgmt` están cargadas:

   ```powershell
   gcloud builds connections describe github --region=$region --project=$mgmt --format="value(installationState.stage)"
   ```

   Debe responder `COMPLETE`. No continúes mientras muestre otro estado.

La aplicación permite que Cloud Build lea esos tres repositorios. No entrega credenciales GCP a GitHub ni a GitHub Actions.

### 13.4 Vincular los repositorios con los triggers deshabilitados

**Directorio de ejecución:** `platform\infra\terraform\environments\delivery`.

En `gcp.auto.tfvars`, cambia solamente:

```hcl
github_connection_ready  = true
release_triggers_enabled = false
```

Genera un plan nuevo; no reutilices `tfplan-connection`:

```powershell
terraform plan -out=tfplan-repositories
terraform show tfplan-repositories
terraform apply tfplan-repositories
```

Este apply vincula los tres repositorios y crea `release-backend`, `release-frontend` y `promote-release`. Los triggers de release continúan deshabilitados.

### 13.5 Habilitar los triggers de release

Confirma primero que `cloudbuild.release.yaml` ya existe en la rama `main` de backend y frontend. Luego, en el mismo `gcp.auto.tfvars`, conserva `github_connection_ready = true` y cambia:

```hcl
release_triggers_enabled = true
```

**Directorio de ejecución:** `platform\infra\terraform\environments\delivery`.

```powershell
terraform plan -out=tfplan-triggers
terraform show tfplan-triggers
terraform apply tfplan-triggers
terraform output release_triggers
```

A partir de este apply, solo un push de un tag SemVer inicia `release-backend` o `release-frontend`. Un PR, un push normal o un merge a `main` no inicia estos builds de release.

### 13.6 Construir la primera release

1. **Crear los tags.** En backend y frontend, publica las releases SemVer desde un commit integrado en `main` (`vX.Y.Z`), según el [manual de versionado](manual-versionado.md).
2. **Esperar Cloud Build.** Comprueba que `release-backend` y `release-frontend` terminaron en `SUCCESS`:

   ```powershell
   gcloud builds list --region=$region --project=$mgmt --filter="trigger_id:*" --limit=5
   ```

3. **Verificar los digests.** Lee la evidencia y compara commit, contrato y digests con los tags reales publicados:

   ```powershell
   $backendTag = "v1.2.0"  # reemplaza por el tag publicado
   $frontendTag = "v0.9.0" # reemplaza por el tag publicado
   gcloud storage cat "gs://${mgmt}-delivery-evidence-backend/sport-app-backend/$backendTag/backend-release.json"
   gcloud storage cat "gs://${mgmt}-delivery-evidence-frontend/frontend/$frontendTag/frontend-release.json"
   gcloud artifacts docker images list "${region}-docker.pkg.dev/$production/sportapp-backend" --include-tags --limit=20
   ```

### 13.7 Crear los servicios Cloud Run con los primeros digests

**Directorio de ejecución:** `platform\infra\terraform\environments\production`.

En `gcp.auto.tfvars`, agrega `cloud_run_images` con las referencias completas `@sha256:...` de `web`, `bff-web` y `bff-mobile` obtenidas de la evidencia. No uses tags ni `latest`. Después ejecuta:

```powershell
terraform plan -out=tfplan-cloud-run-initial
terraform show tfplan-cloud-run-initial
terraform apply tfplan-cloud-run-initial
terraform output cloud_run_urls
```

Este apply crea la primera revisión de los tres servicios. Las imágenes posteriores las administra Cloud Deploy.

### 13.8 Registrar los targets de Cloud Run

**Directorio de ejecución:** `platform\infra\terraform\environments\delivery`.

El estado remoto de `production` ya contiene los servicios Cloud Run. Genera y aplica un plan nuevo para que `delivery` cree sus targets:

```powershell
terraform plan -out=tfplan-cloud-run-targets
terraform show tfplan-cloud-run-targets
terraform apply tfplan-cloud-run-targets
```

Comprueba los pipelines y targets:

```powershell
gcloud deploy delivery-pipelines list --region=$region --project=$mgmt
gcloud deploy targets list --region=$region --project=$mgmt --format="table(name,requireApproval)"
```

Todos los targets deben mostrar `requireApproval: True`.

### 13.9 Promover, aprobar y verificar

1. **Ejecutar el promotor.** Primero el backend y después el frontend ([10.2](#102-separación-de-build-y-promoción)).
2. **Revisar y aprobar.** En **Cloud Deploy → backend-gke**, revisa en la release las anotaciones (commit, Cloud Build, contrato, sha256 de la evidencia) y los digests. Aprueba `production-gke-migrations`; cuando termine, promueve y aprueba `production-gke`. Aprueba después `bff-web`, `bff-mobile` y `frontend-web`. Rechaza si aparece un tag mutable, un commit distinto, una imagen externa o un target inesperado.

   ```powershell
   $release = "REEMPLAZAR_CON_RELEASE"
   $rollout = "REEMPLAZAR_CON_ROLLOUT"
   gcloud deploy releases promote --release=$release --delivery-pipeline=backend-gke --region=$region --project=$mgmt
   gcloud deploy rollouts approve $rollout --release=$release --delivery-pipeline=backend-gke --region=$region --project=$mgmt
   ```

3. **Verificar GKE y Cloud Run.** Las verificaciones de Cloud Deploy deben terminar en `SUCCEEDED`. Revisa además:

   ```powershell
   $cluster = "REEMPLAZAR_CON_CLUSTER"
   gcloud container clusters get-credentials $cluster --location=$region --project=$production --dns-endpoint
   kubectl -n sportapp get deployments,jobs
   gcloud run services list --project=$production --region=$region
   ```

4. **Ejecutar un nuevo `terraform plan`** por separado desde cada directorio: `production`, `production-workloads` y `delivery`.
5. **Confirmar que Terraform no revierte imágenes ni cargas.** Los planes no deben proponer cambios de imagen, revisión o tráfico en Cloud Run ni crear, modificar o borrar Deployments o Jobs. Si lo hacen, no apliques: revisa la sección [6.4](#64-separar-propiedad-terraformcloud-deploy).
6. **Registrar la composición.** En la rama de release de la plataforma, completa [`release-manifest.yaml`](../release-manifest.yaml) con versiones, tags, commits, contratos y digests promovidos, y crea su copia `releases/vX.Y.Z.yaml`, según el [esquema de CI y release](esquema-ci-y-release.md).

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

## 15. Suspender, reanudar, destruir y recrear

La operación diaria empieza aquí después de completar una vez las secciones 1–13. No vuelvas a crear proyectos, vincular facturación, ejecutar el bootstrap ni autorizar la GitHub App.

Para apagar y encender solo el plano costoso, conservando imágenes y secretos, usa `.\scripts\sportapp-gcp.ps1 down` y `up` ([ejecución automatizada](#ejecución-automatizada)). Esta sección describe el procedimiento manual y la destrucción completa de `environments/production`.

| Se conserva | Se puede destruir y recrear |
| --- | --- |
| proyecto `$mgmt` | recursos administrados por `environments/production` |
| proyecto `$production` y su vínculo de facturación | GKE y sus objetos Kubernetes |
| buckets de estado Terraform | Cloud SQL y sus datos, salvo respaldo externo |
| cuentas de servicio e IAM del bootstrap | Cloud Run y sus revisiones |
| conexión de Cloud Build, triggers, pipelines y aprobadores | Artifact Registry y sus imágenes |
| archivos locales `.env.ps1`, `backend.hcl` y `gcp.auto.tfvars` | Pub/Sub, secretos, red y observabilidad de producción |

No ejecutes `terraform destroy` en `bootstrap/gcp-state` ni en `environments/delivery` para apagar producción. Esas raíces pertenecen al plano fijo.

### 15.1 Suspender producción

Úsalo para una pausa corta. La suspensión reduce capacidad, pero no lleva necesariamente el costo a cero porque conserva el clúster, almacenamiento, IP, imágenes, logs y estado.

Carga `.env.ps1` desde la raíz `platform`. Después ubica la consola en `platform\infra\terraform\environments\production` y ejecuta:

```powershell
terraform plan -var="suspended=true" -out=tfplan-suspend
terraform show tfplan-suspend
terraform apply tfplan-suspend
gcloud sql instances list --project $production
gcloud compute instances list --project $production
```

No edites `terraform.tfvars` para una pausa temporal. Conserva como evidencia el resumen del plan aplicado.

### 15.2 Reanudar

Carga `.env.ps1` desde la raíz `platform`. Después ubica la consola en `platform\infra\terraform\environments\production` y ejecuta:

```powershell
terraform plan -var="suspended=false" -out=tfplan-resume
terraform show tfplan-resume
terraform apply tfplan-resume
```

Espera a que Cloud SQL y GKE estén listos antes de promover o reintentar rollouts.

### 15.3 Destruir solamente el plano operativo

Úsalo cuando producción no se utilizará durante varios días o semanas. La destrucción elimina bases de datos, imágenes, secretos y demás recursos administrados por `environments/production`. Exporta previamente cualquier dato o evidencia que debas conservar fuera de esa raíz.

1. Confirma que no haya un rollout o una migración en curso.
2. Revisa los respaldos y exportaciones necesarios.
3. Desde la raíz `platform`, carga `.env.ps1` y comprueba que `$production` sea exactamente el proyecto esperado.
4. Desactiva las protecciones mediante un plan separado y revisado.
5. Genera y revisa el plan de destrucción antes de aplicarlo.

Después ubica la consola en `platform\infra\terraform\environments\production` y ejecuta:

```powershell
terraform plan -var="deletion_protection=false" -var="destroy_confirmation=$production" -out=tfplan-unprotect
terraform show tfplan-unprotect
terraform apply tfplan-unprotect

terraform plan -destroy -var="deletion_protection=false" -var="destroy_confirmation=$production" -out=tfplan-destroy
terraform show tfplan-destroy
terraform apply tfplan-destroy
```

La eliminación del clúster también elimina los objetos físicos de `production-workloads`. No destruyas esa raíz por separado: conserva su estado para que el siguiente `apply` detecte el clúster nuevo y reconcilie los objetos.

Verifica que ya no permanezcan los principales generadores de costo:

```powershell
gcloud container clusters list --project $production
gcloud sql instances list --project $production
gcloud run services list --project $production --region=$region
gcloud artifacts repositories list --project=$production --location=$region
gcloud compute forwarding-rules list --project=$production
```

El resultado esperado es que no existan los recursos administrados por la raíz de producción. El proyecto `$production`, su facturación y el plano fijo de `$mgmt` permanecen disponibles para la recreación.

### 15.4 Recrear producción después de destruirla

No repitas las secciones 1–11. La conexión, los triggers, las identidades y el estado continúan en el proyecto de gestión.

1. Ejecuta la sección [12](#12-crear-o-recrear-la-infraestructura-de-producción) con `cloud_run_images = {}` para reconstruir la infraestructura base y luego `production-workloads`.
2. Artifact Registry también fue recreado vacío. Ejecuta Cloud Build para volver a publicar las imágenes requeridas y verifica sus nuevos digests.
3. Copia los digests de `web`, `bff-web` y `bff-mobile` en `cloud_run_images`; revisa y aplica un nuevo plan de `environments/production` para crear los servicios Cloud Run iniciales.
4. Ejecuta un plan de `environments/delivery` para reconciliar los targets con los recursos recreados. No vuelvas a autorizar GitHub si la conexión continúa en estado `COMPLETE`.
5. Ejecuta el promotor, aprueba los rollouts y realiza las verificaciones de la sección 13.
6. Ejecuta planes finales en `production`, `production-workloads` y `delivery`; no deben revertir imágenes ni cargas administradas por Cloud Deploy.

### 15.5 Comprobar el estado operativo

**Directorio de ejecución:** raíz `platform`.

```powershell
. .\.env.ps1
gcloud container clusters list --project $production
gcloud sql instances list --project $production
gcloud run services list --project $production --region=$region
gcloud artifacts repositories list --project=$production --location=$region
gcloud builds connections describe github --region=$region --project=$mgmt --format="value(installationState.stage)"
```

Los cuatro primeros comandos muestran el plano operativo. El último confirma que la conexión fija de Cloud Build continúa instalada.

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
| `Backend initialization required` | la raíz Terraform actual todavía no fue inicializada con su backend | desde el directorio exacto de esa raíz ejecuta `terraform init "-backend-config=backend.hcl" -reconfigure` |
| `No outputs found` | el estado de la raíz actual no tiene un `apply` exitoso, o el output pertenece a otra raíz | identifica el directorio con la tabla inicial; `artifact_registry_urls` se consulta en `production` solo después de aplicar 12.3 |
| `No positional arguments are expected` durante `init` | se agregó `\` al final o PowerShell separó el argumento del backend | ejecuta exactamente `terraform init "-backend-config=backend.hcl" -reconfigure` en una sola línea |
| `local.production is object with no attributes` al planear `delivery` | `environments/production` todavía no fue aplicado o `state_bucket` apunta al bucket equivocado | detén `delivery`, completa 12.3 y 12.4 y confirma los outputs de producción antes de volver a la sección 13 |
| `service-...@gcp-sa-clouddeploy.iam.gserviceaccount.com does not exist` | el agente de servicio aún no fue creado | ejecuta la habilitación y `gcloud beta services identity create` de 5.3; no repitas todo el bootstrap |
| `iam.serviceAccounts.get denied` al describir un agente administrado | el usuario no puede consultar directamente esa cuenta especial | comprueba el agente mediante `gcloud projects get-iam-policy` como indica 5.3; no otorgues permisos adicionales solo por ese mensaje |
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
