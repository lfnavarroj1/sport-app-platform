# Preparación local y de GCP para Terraform

## Propósito

Esta guía deja lista cada plataforma antes del primer `terraform apply` de SportApp:

- **Local (desarrollo):** Kubernetes de Docker Desktop aprovisionado con **kubeadm**. No requiere credenciales de nube.
- **GCP (producción):** proyectos, facturación, autenticación sin llaves y los archivos de variables donde se indica la cuenta y el proyecto.

La decisión de ambientes está en ADR-022: desarrollo es local y GCP se usa solo para producción. La operación diaria (crear, actualizar y destruir ambientes) está en la [guía de Terraform](../infra/terraform/README.md) de `sport-app-platform`.

## Tabla de contenido

1. [Ambientes](#1-ambientes)
2. [Clonar la plataforma](#2-clonar-la-plataforma)
3. [Herramientas de la estación](#3-herramientas-de-la-estación)
4. [Plataforma local: Kubernetes kubeadm en Docker Desktop](#4-plataforma-local-kubernetes-kubeadm-en-docker-desktop)
   - [4.1 Preparar Docker Desktop](#41-preparar-docker-desktop)
   - [4.2 Activar Kubernetes con kubeadm](#42-activar-kubernetes-con-kubeadm)
   - [4.3 Verificar que el clúster es kubeadm](#43-verificar-que-el-clúster-es-kubeadm)
   - [4.4 Preparar las imágenes de backend y frontend](#44-preparar-las-imágenes-de-backend-y-frontend)
   - [4.5 Archivo de variables local](#45-archivo-de-variables-local)
   - [4.6 Primer apply](#46-primer-apply)
   - [4.7 Actualizar backend y frontend](#47-actualizar-backend-y-frontend)
5. [Plataforma GCP: producción](#5-plataforma-gcp-producción)
   - [5.1 Decidir los identificadores](#51-decidir-los-identificadores)
   - [5.2 Crear los proyectos y vincular la facturación](#52-crear-los-proyectos-y-vincular-la-facturación)
   - [5.3 Autenticarse sin llaves](#53-autenticarse-sin-llaves)
   - [5.4 Completar bootstrap.auto.tfvars](#54-completar-bootstrapautotfvars)
   - [5.5 Ejecutar el bootstrap](#55-ejecutar-el-bootstrap)
   - [5.6 Completar gcp.auto.tfvars y backend.hcl](#56-completar-gcpautotfvars-y-backendhcl)
   - [5.7 Verificar el acceso](#57-verificar-el-acceso)
   - [5.8 Preparar GitHub Actions](#58-preparar-github-actions)
6. [Qué archivos van a Git](#6-qué-archivos-van-a-git)
7. [Lista de verificación](#7-lista-de-verificación)
8. [Problemas frecuentes](#8-problemas-frecuentes)
9. [Apagar y volver a encender](#9-apagar-y-volver-a-encender)
   - [9.1 Desarrollo local](#91-desarrollo-local)
   - [9.2 Producción: suspender](#92-producción-suspender)
   - [9.3 Producción: destruir](#93-producción-destruir)

## 1. Ambientes

| | Desarrollo | Producción |
| --- | --- | --- |
| Plataforma | Kubernetes kubeadm de Docker Desktop | Google Cloud Platform |
| Raíz Terraform | `infra/terraform/environments/local` | `infra/terraform/environments/production` |
| Preparación única | activar Kubernetes ([4](#4-plataforma-local-kubernetes-kubeadm-en-docker-desktop)) | proyectos y bootstrap ([5](#5-plataforma-gcp-producción)) |
| Credenciales | ninguna | tu sesión de Google con impersonación, o WIF en CI |
| Archivos que completas | `local.auto.tfvars` (opcional) | `bootstrap.auto.tfvars`, `gcp.auto.tfvars` y `backend.hcl` |
| Estado Terraform | archivo local ignorado por Git | bucket GCS del proyecto de gestión |
| Costo | ninguno en la nube | facturado por GCP |

`staging` no existe todavía.

## 2. Clonar la plataforma

Clona la plataforma como carpeta hermana de los repositorios de componentes, sin inicializar submódulos:

```powershell
cd "D:\04 - Mestría en Ingeniería de Software\08 - Ciclo 8\Proyecto final II\aplicacion_proyecto_final"
git clone --no-recurse-submodules https://github.com/lfnavarroj1/sport-app-platform.git platform
cd platform
git config --local submodule.recurse false
git config --local fetch.recurseSubmodules false
git config --local push.recurseSubmodules no
git submodule status        # las tres líneas deben comenzar con "-"
```

Estructura esperada:

```text
aplicacion_proyecto_final/
├── backend/        # sport-app-backend: lo usa el ambiente local
├── frontend/       # sport-app-frontend: imagen sportapp/web
├── movil/
├── documentacion/
└── platform/       # sport-app-platform: Terraform
```

## 3. Herramientas de la estación

| Herramienta | Local | GCP | Instalación | Verificación |
| --- | --- | --- | --- | --- |
| Docker Desktop | sí | — | instalador oficial | `docker version` |
| `kubectl` | sí | opcional | `winget install --id Kubernetes.kubectl -e` | `kubectl version --client` |
| Terraform ≥ 1.11 | sí | sí | `winget install --id Hashicorp.Terraform -e` | `terraform version` |
| Google Cloud CLI | — | sí | `winget install --id Google.CloudSDK -e` | `gcloud version` |
| Git | sí | sí | `winget install --id Git.Git -e` | `git version` |
| GitHub CLI | — | para CI | `winget install --id GitHub.cli -e` | `gh --version` |
| Python 3.13 y uv | sí (para construir el backend) | — | README del backend, pasos 2 y 5 | `py -3.13 -m uv --version` |
| Node.js 24.14.0 | solo para `npm start` del frontend; la imagen se construye con Docker | — | versión de `frontend/.nvmrc` | `node --version` |

Después de instalar, cierra y vuelve a abrir PowerShell para que se actualice el `PATH`.

## 4. Plataforma local: Kubernetes kubeadm en Docker Desktop

### 4.1 Preparar Docker Desktop

1. Abre Docker Desktop y espera a que indique *Engine running*.
2. Confirma que usa contenedores Linux con WSL 2: *Settings → General → Use the WSL 2 based engine*.
3. El ambiente completo usa alrededor de 4 a 6 GB de RAM. Si Docker Desktop muestra límites en *Settings → Resources → Advanced*, asigna al menos 4 CPU y 8 GB.

```powershell
docker version --format "Cliente {{.Client.Version}} / Servidor {{.Server.Version}}"
```

### 4.2 Activar Kubernetes con kubeadm

La interfaz cambia según la versión de Docker Desktop.

**Versiones recientes** (hay un ítem **Kubernetes** en el menú lateral):

1. Pulsa **Kubernetes** en el menú lateral.
2. Pulsa **Create cluster** (o activa *Enable Kubernetes*).
3. En el método de aprovisionamiento, elige **kubeadm**.
4. Confirma con **Create** o **Apply**.

**Versiones anteriores:**

1. *Settings → Kubernetes*.
2. Marca **Enable Kubernetes**.
3. Si pregunta el método de aprovisionamiento, elige **kubeadm**.
4. Pulsa **Apply & restart**.

La primera vez se descargan las imágenes del clúster, lo que tarda entre 2 y 10 minutos. Termina cuando Kubernetes aparece como **running** en verde.

**Por qué kubeadm y no kind:** con kubeadm el clúster usa el motor Docker del equipo como runtime. Las imágenes que construyes con `docker build` quedan disponibles en Kubernetes sin registro ni carga manual. Con kind habría que cargar cada imagen en los nodos.

### 4.3 Verificar que el clúster es kubeadm

Usa siempre `--context docker-desktop`. El contexto activo de `kubectl` puede ser un clúster GKE de otro proyecto.

```powershell
kubectl config get-contexts                               # debe existir docker-desktop
kubectl --context docker-desktop get nodes -o wide        # nodo docker-desktop en Ready, runtime docker://
kubectl --context docker-desktop -n kube-system get pods  # etcd-, kube-apiserver-, kube-scheduler-docker-desktop
kubectl --context docker-desktop -n kube-system get configmap kubeadm-config
```

Resultado esperado:

| Comprobación | Valor esperado |
| --- | --- |
| Nodo | `docker-desktop`, `Ready`, rol `control-plane` |
| Runtime | `docker://…` (comparte imágenes con Docker) |
| Plano de control | pods estáticos `etcd-docker-desktop`, `kube-apiserver-docker-desktop`, etc. |
| `kubeadm-config` | existe en `kube-system` |
| `StorageClass` | `hostpath (default)` |

No hace falta cambiar el contexto activo: la raíz Terraform local fija `docker-desktop` y rechaza cualquier otro.

### 4.4 Preparar las imágenes de backend y frontend

Cada imagen se construye desde **su propio repositorio** y queda en el Docker del equipo, que el clúster kubeadm usa directamente. La misma imagen es la que se publica para producción.

| Componente | Repositorio | Imágenes | Comando |
| --- | --- | --- | --- |
| Backend | `aplicacion_proyecto_final\backend` | 8 imágenes `sportapp/<componente>:local` | `py -3.13 -m uv run python scripts/task.py build all` |
| Frontend | `aplicacion_proyecto_final\frontend` | `sportapp/web:local` | `docker build -t sportapp/web:local .` |

```powershell
cd ..\backend
py -3.13 -m uv run python scripts/task.py build all

cd ..\frontend
docker build -t sportapp/web:local .

docker images "sportapp/*"      # 9 imágenes
```

El ambiente local despliega el frontend en el clúster con la misma imagen que se publica para Cloud Run, y lo publica en `http://localhost:18082`. Para programar con recarga automática, `npm start` sigue disponible en `http://localhost:4200` (guía de Terraform, sección 5.3).

### 4.5 Archivo de variables local

Es opcional y **no contiene credenciales**. Solo hace falta si el backend no es carpeta hermana o si usas otro tag de imagen.

```powershell
cd ..\platform\infra\terraform\environments\local
Copy-Item local.auto.tfvars.example local.auto.tfvars    # ignorado por Git
notepad local.auto.tfvars
```

| Variable | Para qué | Valor por defecto |
| --- | --- | --- |
| `backend_path` | ruta del repositorio backend relativa a esta carpeta | `../../../../../backend` |
| `backend_image_tag` | tag de las imágenes construidas | `local` |
| `backend_image_tags` | tag por componente reconstruido | `{}` |
| `deploy_backend` | `false` deja solo PostgreSQL y Pub/Sub | `true` |
| `frontend_path` | ruta del repositorio frontend relativa a esta carpeta | `../../../../../frontend` |
| `frontend_image_tag` | tag de `sportapp/web` | `local` |
| `deploy_frontend` | `false` no despliega la web (por ejemplo, para usar solo `npm start`) | `true` |
| `log_level` | nivel de log | `INFO` |
| `jwt_key_revision` | versión de la clave local; increméntala solo para rotarla e invalidar sesiones | `1` |

Las contraseñas de PostgreSQL y la clave Ed25519 de firma JWT las genera Terraform en los Secrets `sportapp-database` y `sportapp-users-jwt`. Se entregan mediante argumentos *write-only* y no se guardan en el plan ni en el estado.

### 4.6 Primer apply

```powershell
terraform init
terraform plan -out=tfplan
terraform apply tfplan
kubectl --context docker-desktop --namespace sportapp-local get pods
curl.exe http://localhost:18080/health/ready
curl.exe http://localhost:18082/healthz          # aplicación web
```

La plataforma local queda lista cuando todos los pods están en `Running`, los Jobs en `Complete` y el BFF responde `200`. La aplicación web se abre en `http://localhost:18082`. El uso diario continúa en la guía de Terraform (sección 4).

### 4.7 Actualizar backend y frontend

Las secciones 4.1 a 4.6 se hacen **una sola vez**. Cuando cambia el código del backend no se actualiza la infraestructura: PostgreSQL, el emulador, los secretos y la configuración quedan intactos. Solo se reemplaza la imagen de los componentes que cambiaron.

Elige la forma según el cambio:

| Situación | Qué se hace | Tiempo |
| --- | --- | --- |
| A. Programando activamente un servicio | ejecutarlo en el host con recarga automática, contra la base y el Pub/Sub del clúster | inmediato; sin imagen ni `apply` |
| B. Cambio sin migraciones | reconstruir con el mismo tag `local` y reiniciar el Deployment | segundos |
| C. Cambio con migraciones, o varios componentes | construir con un tag nuevo y ejecutar `terraform apply` | alrededor de 30 segundos |

Los nombres de componente son: `users-management`, `affiliation-management`, `complementary-services`, `training-management`, `events-management`, `third-party-management`, `bff-web` y `bff-mobile`.

**A. Servicio en el host.** Se usan los accesos que el clúster publica en `localhost`: PostgreSQL en `15432` y el emulador en `18085`. La configuración y la contraseña se obtienen como indica la guía de Terraform, sección 4.6. Si no quieres que la versión del clúster atienda en paralelo, aplica con `-var="deploy_backend=false"`.

**B. Cambio sin migraciones.** En `aplicacion_proyecto_final\backend`:

```powershell
py -3.13 -m uv run python scripts/task.py build users-management
kubectl --context docker-desktop --namespace sportapp-local rollout restart deployment/users-management
kubectl --context docker-desktop --namespace sportapp-local rollout status deployment/users-management
```

Funciona porque el clúster kubeadm comparte las imágenes con Docker: al reiniciar, el pod toma la imagen recién construida con el tag `local`. Si el componente tiene publicador outbox (hoy, `users-management`), reinicia también `deployment/users-management-outbox-publisher`. Este reinicio **no** vuelve a ejecutar las migraciones.

**C. Cambio con migraciones, o varios componentes.** En `aplicacion_proyecto_final\backend`:

```powershell
$tag = "dev-" + (Get-Date -Format "yyyyMMdd-HHmm")
py -3.13 -m uv run python scripts/task.py build all --tag $tag
```

En `platform\infra\terraform\environments\local`:

```powershell
terraform plan -out=tfplan -var="backend_image_tag=$tag"
terraform apply tfplan
kubectl --context docker-desktop --namespace sportapp-local get pods,jobs
```

El plan debe mostrar los Deployments como *update in-place* y los Jobs de migración como *must be replaced*: las migraciones se ejecutan de nuevo y luego los pods pasan a la imagen nueva. Para no repetir el tag en cada comando, guárdalo como `backend_image_tag` en `local.auto.tfvars`. Si reconstruiste solo algunos componentes, declara únicamente esos en `backend_image_tags` dentro del mismo archivo.

**Si cambiaron los manifiestos del backend** (`deploy/k8s/base`: un componente, una variable o un Job nuevos), basta con actualizar el clon del backend y ejecutar `terraform plan` y `terraform apply`. Terraform lee los manifiestos directamente del clon.

**Frontend.** En `aplicacion_proyecto_final\frontend`:

```powershell
docker build -t sportapp/web:local .
kubectl --context docker-desktop --namespace sportapp-local rollout restart deployment/web
kubectl --context docker-desktop --namespace sportapp-local rollout status deployment/web
```

El frontend no tiene migraciones, así que el reinicio basta. Para programar con recarga automática, sigue disponible `npm start`.

Las imágenes antiguas se limpian con `docker image prune`.

## 5. Plataforma GCP: producción

Esta preparación se hace **una sola vez** y modifica recursos facturables. Ejecútala solo después de revisar nombres, permisos y presupuesto.

### 5.1 Decidir los identificadores

Los ID de proyecto son únicos a nivel global y no se pueden cambiar. Son identificadores, no secretos. Hay dos formas de definirlos.

**Opción A: directamente en la terminal.** Se pierden al cerrar PowerShell.

```powershell
$billing    = "XXXXXX-XXXXXX-XXXXXX"     # gcloud billing accounts list
$mgmt       = "sportapp-mgmt-1234"       # estado e identidades; nunca se destruye
$production = "sportapp-prod-1234"       # cargas de producción
```

**Opción B: guardados en `platform\.env.ps1` y cargados en cada terminal.** El archivo es local: Git lo ignora porque el `.gitignore` excluye `.env.*`. Nunca pongas llaves ni tokens en él.

```powershell
# platform\.env.ps1
$billing    = "XXXXXX-XXXXXX-XXXXXX"
$mgmt       = "sportapp-mgmt-1234"
$production = "sportapp-prod-1234"
```

Para cargarlo, desde `platform`, usa *dot-sourcing*. El punto inicial deja las variables en la sesión actual:

```powershell
. .\.env.ps1
$production      # comprobación
```

Estas variables solo las usan los comandos `gcloud` y las secciones [5](#5-plataforma-gcp-producción) y [9](#9-apagar-y-volver-a-encender). Terraform no las lee: toma sus valores de `bootstrap.auto.tfvars`, `gcp.auto.tfvars` y `backend.hcl`.

La región adoptada es `us-central1`. Antes de usarla, confirma los requisitos de residencia de datos, latencia y costo.

### 5.2 Crear los proyectos y vincular la facturación

```powershell
gcloud auth login
gcloud projects create $mgmt --name="SportApp gestion"
gcloud projects create $production --name="SportApp produccion"
gcloud billing projects link $mgmt --billing-account=$billing
gcloud billing projects link $production --billing-account=$billing
```

Quien ejecute el bootstrap necesita `roles/owner` en ambos proyectos y `roles/billing.costsManager` en la cuenta de facturación, para crear el presupuesto.

No hace falta habilitar APIs a mano. El bootstrap habilita las del proyecto de gestión (IAM, STS, Storage y presupuestos) y las mínimas del de producción. La raíz de producción habilita el resto: Compute, GKE, Cloud Run, Cloud SQL, Pub/Sub, Secret Manager, Artifact Registry, Logging y Monitoring.

### 5.3 Autenticarse sin llaves

Terraform usa **Application Default Credentials (ADC)**, es decir, tu propia sesión de Google:

```powershell
gcloud auth application-default login
```

Este comando crea `%APPDATA%\gcloud\application_default_credentials.json`, que queda fuera del repositorio. **Nunca** lo copies al proyecto, nunca descargues llaves JSON de cuentas de servicio y nunca agregues `credentials = file(...)` al proveedor.

A partir del bootstrap, Terraform no actúa con tus permisos personales: impersona la cuenta `tf-apply-production`, que el bootstrap autoriza solo a los operadores declarados.

### 5.4 Completar bootstrap.auto.tfvars

```powershell
cd infra\terraform\bootstrap\gcp-state
Copy-Item bootstrap.auto.tfvars.example bootstrap.auto.tfvars   # ignorado por Git
notepad bootstrap.auto.tfvars
```

| Campo | Qué poner |
| --- | --- |
| `management_project_id` | `$mgmt` |
| `region` | `us-central1` |
| `github_repository` | `lfnavarroj1/sport-app-platform` |
| `environments.production.project_id` | `$production` |
| `environments.production.operators` | `["user:<tu-correo>"]`: quienes pueden ejecutar Terraform en producción |
| `environments.production.budget_amount` | presupuesto mensual; la estimación de costos fija `1000` (USD) como tope inicial |
| `environments.production.budget_alert_amounts` | montos en los que quieres recibir aviso, por ejemplo `[50, 100, 250, 500]`. También se avisa al 100 % y cuando el pronóstico supera el presupuesto. Si se deja vacío, los avisos son al 50 %, 90 % y 100 % |
| `environments.production.component_delivery` | `true`: backend y frontend publican imágenes de release |
| `billing_account` | `$billing` |
| `budget_currency` | moneda de la cuenta de facturación (`USD`, `COP`, …) |

### 5.5 Ejecutar el bootstrap

```powershell
terraform init
terraform plan -out=tfplan
terraform apply tfplan
terraform output
```

| Salida | Dónde se usa |
| --- | --- |
| `state_buckets.production` | `bucket` en `backend.hcl` |
| `apply_service_accounts.production` | `impersonate_service_account` en `gcp.auto.tfvars` y `backend.hcl` |
| `plan_service_accounts.production` | variable `PROD_TF_PLAN_SA` de GitHub |
| `delivery_service_accounts.production` | `artifact_registry_writers` y variable `GCP_DELIVERY_SERVICE_ACCOUNT` de backend/frontend |
| `workload_identity_provider` | variable `GCP_WORKLOAD_IDENTITY_PROVIDER` de los workflows |

El estado del bootstrap queda en `terraform.tfstate`, en esa carpeta e ignorado por Git. Respáldalo o mígralo al bucket siguiendo el comentario de `versions.tf`.

### 5.6 Completar gcp.auto.tfvars y backend.hcl

Estos son los archivos donde se indican la cuenta y el proyecto de producción. No contienen secretos.

```powershell
cd ..\..\environments\production
Copy-Item gcp.auto.tfvars.example gcp.auto.tfvars     # ignorado por Git
Copy-Item backend.hcl.example backend.hcl             # ignorado por Git
notepad gcp.auto.tfvars
notepad backend.hcl
```

**`gcp.auto.tfvars`**

| Campo | Qué poner |
| --- | --- |
| `project_id` | `$production` |
| `impersonate_service_account` | salida `apply_service_accounts.production` |
| `alert_emails` | correos que reciben las alertas |
| `gke_authorized_networks` | opcional: tu IP pública `/32` para `kubectl` por IP |
| `artifact_registry_writers` | `{ component-ci = "serviceAccount:<delivery_service_accounts.production>" }` |
| `labels` | por ejemplo `{ owner = "equipo-sportapp" }` |

**`backend.hcl`**

| Campo | Qué poner |
| --- | --- |
| `bucket` | salida `state_buckets.production` |
| `impersonate_service_account` | la misma cuenta `tf-apply-production` (solo en tu equipo; en CI se omite) |

Los tamaños, la red y los digests de imágenes **no** van aquí: están en `terraform.tfvars`, que se versiona y se revisa en PR.

### 5.7 Verificar el acceso

```powershell
gcloud auth print-access-token --impersonate-service-account=tf-apply-production@$mgmt.iam.gserviceaccount.com
terraform init -backend-config=backend.hcl
terraform validate
terraform plan -out=tfplan
```

- **El token se imprime:** la impersonación funciona.
- **Responde 403:** tu usuario no está en `operators`.
- **`plan` termina sin errores:** la plataforma GCP está lista. El `apply` y su revisión se describen en la guía de Terraform (sección 6.6).

### 5.8 Preparar GitHub Actions

GitHub Actions usa WIF: credenciales temporales por OIDC, nunca llaves en *Secrets*.

1. En `sport-app-platform`, crea el Environment `production` con *required reviewers*.
2. Crea las variables del repositorio `GCP_WORKLOAD_IDENTITY_PROVIDER`, `PROD_PROJECT_ID`, `PROD_STATE_BUCKET`, `PROD_TF_PLAN_SA`, `PROD_TF_APPLY_SA`, `PROD_ALERT_EMAILS` y `PROD_ARTIFACT_REGISTRY_WRITERS`.
3. En backend y frontend, crea el Environment `production` con `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_DELIVERY_SERVICE_ACCOUNT`, `GCP_ARTIFACT_REGISTRY` y `GCP_ARTIFACT_REGISTRY_HOST`. Los usan los workflows de release que publican las imágenes del backend y la imagen `web` del frontend (`release-web.yml`) en Artifact Registry; el despliegue lo hace Terraform.

```powershell
gh variable set PROD_TF_APPLY_SA --repo lfnavarroj1/sport-app-platform --body "tf-apply-production@$mgmt.iam.gserviceaccount.com"
```

## 6. Qué archivos van a Git

| Archivo | Plataforma | ¿Git? | Contenido |
| --- | --- | --- | --- |
| `*.tf`, `.terraform.lock.hcl`, `tests/*.tftest.hcl` | ambas | sí | código y versiones fijadas |
| `environments/production/terraform.tfvars` | GCP | sí | tamaños, red y digests; sin secretos |
| `*.example` | ambas | sí | plantillas con marcadores |
| `environments/local/local.auto.tfvars` | local | no | ruta del backend y tags |
| `bootstrap/gcp-state/bootstrap.auto.tfvars` | GCP | no | proyectos, operadores y facturación |
| `environments/production/gcp.auto.tfvars` | GCP | no | proyecto, cuenta a impersonar y correos |
| `environments/production/backend.hcl` | GCP | no | bucket del estado |
| `terraform.tfstate*`, `tfplan*`, `.terraform/` | ambas | no | estado, planes y proveedores |
| `application_default_credentials.json` | GCP | **nunca**; vive en `%APPDATA%\gcloud` | tu sesión |
| llaves JSON de cuentas de servicio | — | **nunca**; no se crean | — |

El `.gitignore` de la plataforma ya cubre todos los casos. Antes de un commit, revisa `git status --short` y `git diff --cached`.

## 7. Lista de verificación

### Local

- [ ] Docker Desktop usa WSL 2 y contenedores Linux.
- [ ] Kubernetes está en verde y fue creado con **kubeadm**.
- [ ] `kubectl --context docker-desktop get nodes` muestra `Ready` y runtime `docker://`.
- [ ] Las 8 imágenes del backend `sportapp/*` existen en `docker images`.
- [ ] La imagen `sportapp/web:local` del frontend existe.
- [ ] `terraform apply` en `environments/local` deja todos los pods en `Running`.
- [ ] `http://localhost:18080/health/ready` responde `200`.
- [ ] `http://localhost:18082/healthz` responde `200` y la web abre en el navegador.

### GCP

- [ ] Existen los proyectos de gestión y producción, con facturación vinculada.
- [ ] `gcloud auth application-default login` está hecho; no existen llaves JSON.
- [ ] El bootstrap se aplicó y su estado está respaldado.
- [ ] El presupuesto de producción existe.
- [ ] `gcp.auto.tfvars` y `backend.hcl` están completos y fuera de Git.
- [ ] La impersonación de `tf-apply-production` devuelve un token.
- [ ] `terraform plan` de producción termina sin errores.
- [ ] Para CI: el Environment `production` exige revisores y las variables están creadas.

## 8. Problemas frecuentes

| Síntoma | Causa | Solución |
| --- | --- | --- |
| No existe el contexto `docker-desktop` | Kubernetes no está activado | [4.2](#42-activar-kubernetes-con-kubeadm) |
| Pods en `ErrImagePull` con imágenes `sportapp/*` | el clúster es kind o falta la imagen | recrea el clúster con kubeadm o ejecuta [4.4](#44-preparar-las-imágenes-de-backend-y-frontend) |
| *Kubernetes failed to start* | estado corrupto del clúster | *Settings → Kubernetes → Reset Kubernetes cluster* |
| `El ambiente local solo se aplica en el contexto docker-desktop` | se pasó otro contexto | no cambies `kube_context` |
| `gcloud projects create` falla por el ID | el ID ya existe en GCP | elige otro sufijo |
| 403 al impersonar | tu usuario no está en `operators` | agrégalo en `bootstrap.auto.tfvars` y aplica el bootstrap |
| `Error: Failed to get existing workspaces` en `init` | el bucket de `backend.hcl` es incorrecto | copia `state_buckets.production` |

## 9. Apagar y volver a encender

Antes de empezar, define los identificadores en la terminal o cárgalos desde `platform`, como en [5.1](#51-decidir-los-identificadores):

```powershell
. .\.env.ps1
```

| Situación | Ambiente | Modo | Costo mientras está apagado |
| --- | --- | --- | --- |
| Terminar la jornada | desarrollo | detener Docker Desktop | ninguno |
| Liberar el equipo o empezar de cero | desarrollo | `terraform destroy` | ninguno |
| Pausa corta conservando datos | producción | suspender ([9.2](#92-producción-suspender)) | tarifa del clúster GKE (unos USD 73 al mes, según la estimación de costos), almacenamiento y respaldos de Cloud SQL, Artifact Registry y logs |
| Pausa larga o fin del periodo | producción | destruir ([9.3](#93-producción-destruir)) | casi cero: solo el bucket de estado del proyecto de gestión |

### 9.1 Desarrollo local

| Quiero… | Cómo | Qué se conserva |
| --- | --- | --- |
| Pausar | cerrar Docker Desktop (*Quit Docker Desktop*); al abrirlo, Kubernetes vuelve a levantar los pods | todo |
| Apagar y borrar | `terraform destroy` en `infra\terraform\environments\local` | nada: se borran el namespace y los datos de PostgreSQL |
| Volver a encender tras destruir | `terraform apply` en la misma carpeta | base vacía y contraseñas nuevas |

### 9.2 Producción: suspender

Suspender detiene Cloud SQL, deja Cloud Run con mínimo 0 instancias y lleva el grupo de nodos de GKE a 0. Se conservan la red, el clúster, la base de datos, los secretos y las imágenes.

1. En `infra\terraform\environments\production\terraform.tfvars`, agrega o cambia la línea:

   ```hcl
   suspended = true
   ```

   El estado queda en un archivo versionado para que cualquier `plan`, incluido el de CI, lo respete. Un `plan` sin esa línea reanudaría producción.

2. Genera el plan, revísalo y aplícalo:

   ```powershell
   cd infra\terraform\environments\production
   terraform plan -out=tfplan
   terraform show tfplan     # Cloud SQL con activation_policy NEVER, Cloud Run con mínimo 0, nodos en 0
   terraform apply tfplan
   ```

3. Verifica:

   ```powershell
   gcloud sql instances list --project $production                 # estado STOPPED
   gcloud compute instances list --project $production             # sin nodos gke-*
   ```

**Reanudar:** cambia a `suspended = false`, genera el plan y aplícalo. Cloud SQL arranca en unos minutos, Cloud Run vuelve a su mínimo y GKE recupera el autoescalado. Los nodos regresan cuando hay pods pendientes, así que las cargas de GKE pueden tardar unos minutos en estar listas.

### 9.3 Producción: destruir

Destruir elimina todos los recursos del proyecto de producción. **Se pierden** los datos de Cloud SQL, que se borran junto con sus respaldos, las imágenes de Artifact Registry y los valores de los secretos de aplicación. **Se conservan** el proyecto de gestión, el bucket de estado, las cuentas `tf-*` y `ci-delivery-*`, el presupuesto y el proyecto de producción vacío con sus APIs habilitadas.

1. **Opcional: conserva los datos.** Exporta antes las bases que quieras guardar con `gcloud sql export sql` hacia un bucket que no pertenezca a la raíz de producción.

2. **Desactiva la protección contra borrado.** El módulo solo lo permite si escribes el ID del proyecto como confirmación:

   ```powershell
   cd infra\terraform\environments\production
   terraform plan -var="deletion_protection=false" -var="destroy_confirmation=$production" -out=tfplan
   terraform apply tfplan
   ```

3. **Destruye** con un plan revisado, usando las mismas variables:

   ```powershell
   terraform plan -destroy -var="deletion_protection=false" -var="destroy_confirmation=$production" -out=tfplan-destroy
   terraform show tfplan-destroy
   terraform apply tfplan-destroy
   ```

   Si falla la conexión de Private Services Access porque Cloud SQL acaba de eliminarse, repite este paso unos minutos después.

4. **Verifica:**

   ```powershell
   gcloud container clusters list --project $production    # vacío
   gcloud sql instances list --project $production         # vacío
   ```

**Volver a encender:** ejecuta `terraform plan -out=tfplan` y `terraform apply tfplan` **sin** esas variables. La protección contra borrado vuelve a activarse desde `terraform.tfvars`. La primera aplicación tarda entre 20 y 30 minutos. Después hay que volver a publicar las imágenes, cargar los valores de los secretos de aplicación y desplegar las cargas. Las contraseñas de base de datos son nuevas y la base queda vacía, salvo que restaures la exportación del paso 1.

## Referencias oficiales

- [Docker Desktop: Kubernetes](https://docs.docker.com/desktop/use-desktop/kubernetes/)
- [HashiCorp: instalar Terraform](https://developer.hashicorp.com/terraform/install)
- [Google Cloud: autenticación para Terraform](https://docs.cloud.google.com/docs/terraform/authentication)
- [HashiCorp: backend GCS](https://developer.hashicorp.com/terraform/language/backend/gcs)
- [Google Cloud: WIF para pipelines](https://docs.cloud.google.com/iam/docs/best-practices-for-using-service-accounts-in-deployment-pipelines)
- [Google Cloud: presupuestos y alertas](https://docs.cloud.google.com/billing/docs/how-to/budgets)
