# Preparación local para Terraform

## Propósito

Esta guía deja listo el ambiente de desarrollo local de SportApp antes del primer `terraform apply`. Desarrollo corre en Kubernetes de Docker Desktop aprovisionado con **kubeadm** y no requiere credenciales de nube.

La preparación de producción está separada en [Preparación de GCP para Terraform y entrega](preparacion-terraform-gcp.md). La operación diaria de los ambientes se describe en la [guía de Terraform](../infra/terraform/README.md).

## Contenido

1. [Arquitectura local](#1-arquitectura-local)
2. [Clonar la plataforma](#2-clonar-la-plataforma)
3. [Herramientas](#3-herramientas)
4. [Preparar Docker Desktop y Kubernetes](#4-preparar-docker-desktop-y-kubernetes)
5. [Construir las imágenes](#5-construir-las-imágenes)
6. [Configurar y aplicar Terraform](#6-configurar-y-aplicar-terraform)
7. [Actualizar backend y frontend](#7-actualizar-backend-y-frontend)
8. [Archivos locales y Git](#8-archivos-locales-y-git)
9. [Lista de verificación](#9-lista-de-verificación)
10. [Problemas frecuentes](#10-problemas-frecuentes)
11. [Pausar o eliminar el ambiente](#11-pausar-o-eliminar-el-ambiente)

## 1. Arquitectura local

| Aspecto | Valor |
| --- | --- |
| Plataforma | Kubernetes kubeadm de Docker Desktop |
| Raíz Terraform | `infra/terraform/environments/local` |
| Credenciales | ninguna |
| Estado Terraform | archivo local ignorado por Git |
| Registro de imágenes | Docker local compartido con kubeadm |
| Namespace | `sportapp-local` |
| Costo de nube | ninguno |

La raíz local crea PostgreSQL, el emulador de Pub/Sub, secretos locales, configuración, Jobs de migración y los workloads de backend y frontend. Usa siempre el contexto `docker-desktop`.

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
├── backend/        # sport-app-backend
├── frontend/       # sport-app-frontend
├── movil/
├── documentacion/
└── platform/       # sport-app-platform y Terraform
```

## 3. Herramientas

| Herramienta | Uso | Instalación | Verificación |
| --- | --- | --- | --- |
| Docker Desktop | contenedores y clúster local | instalador oficial | `docker version` |
| `kubectl` | inspección y rollouts | `winget install --id Kubernetes.kubectl -e` | `kubectl version --client` |
| Terraform ≥ 1.11 | composición local | `winget install --id Hashicorp.Terraform -e` | `terraform version` |
| Git | repositorios | `winget install --id Git.Git -e` | `git version` |
| Python 3.13 y uv | construir backend | README del backend | `py -3.13 -m uv --version` |
| Node.js 24.14.0 | `npm start` del frontend | versión de `frontend/.nvmrc` | `node --version` |

Después de instalar, cierra y vuelve a abrir PowerShell para actualizar el `PATH`.

## 4. Preparar Docker Desktop y Kubernetes

### 4.1 Preparar Docker Desktop

1. Abre Docker Desktop y espera **Engine running**.
2. Confirma *Settings → General → Use the WSL 2 based engine*.
3. Usa contenedores Linux.
4. Si Docker Desktop muestra límites de recursos, asigna al menos 4 CPU y 8 GB de RAM.

```powershell
docker version --format "Cliente {{.Client.Version}} / Servidor {{.Server.Version}}"
```

### 4.2 Activar Kubernetes con kubeadm

En versiones recientes:

1. Abre **Kubernetes** en el menú lateral.
2. Pulsa **Create cluster** o activa *Enable Kubernetes*.
3. Elige **kubeadm** como método de aprovisionamiento.
4. Confirma y espera hasta que Kubernetes aparezca en verde.

En versiones anteriores usa *Settings → Kubernetes → Enable Kubernetes → Apply & restart* y selecciona kubeadm cuando se solicite.

Kubeadm comparte el motor de imágenes con Docker Desktop. Por eso las imágenes construidas con `docker build` quedan disponibles en el clúster sin publicarlas en un registro. No uses kind para esta composición.

### 4.3 Verificar el clúster

```powershell
kubectl config get-contexts
kubectl --context docker-desktop get nodes -o wide
kubectl --context docker-desktop -n kube-system get pods
kubectl --context docker-desktop -n kube-system get configmap kubeadm-config
kubectl --context docker-desktop get storageclass
```

Resultado esperado:

| Comprobación | Valor esperado |
| --- | --- |
| Nodo | `docker-desktop`, `Ready`, rol `control-plane` |
| Runtime | `docker://…` |
| Plano de control | pods `etcd`, `kube-apiserver` y `kube-scheduler` de Docker Desktop |
| ConfigMap | `kubeadm-config` existe |
| StorageClass | `hostpath` predeterminada |

No es necesario cambiar el contexto activo: Terraform fija `docker-desktop` y rechaza otro contexto.

## 5. Construir las imágenes

Cada imagen se construye desde su repositorio y permanece en Docker local.

| Componente | Imágenes | Comando |
| --- | --- | --- |
| Backend | 8 imágenes `sportapp/<componente>:local` | `py -3.13 -m uv run python scripts/task.py build all` |
| Frontend | `sportapp/web:local` | `docker build -t sportapp/web:local .` |

```powershell
cd ..\backend
py -3.13 -m uv run python scripts/task.py build all

cd ..\frontend
docker build -t sportapp/web:local .

docker images "sportapp/*"      # 9 imágenes
```

El frontend del clúster queda disponible en `http://localhost:18082`. Para desarrollo con recarga automática se puede ejecutar `npm start` en `http://localhost:4200`.

## 6. Configurar y aplicar Terraform

### 6.1 Variables locales

`local.auto.tfvars` es opcional y no contiene credenciales. Úsalo cuando los repositorios no sean carpetas hermanas o se necesiten tags diferentes.

```powershell
cd ..\platform\infra\terraform\environments\local
Copy-Item local.auto.tfvars.example local.auto.tfvars
notepad local.auto.tfvars
```

| Variable | Propósito | Valor predeterminado |
| --- | --- | --- |
| `backend_path` | ruta al backend | `../../../../../backend` |
| `backend_image_tag` | tag general del backend | `local` |
| `backend_image_tags` | tag por componente | `{}` |
| `deploy_backend` | `false` omite los workloads del backend | `true` |
| `frontend_path` | ruta al frontend | `../../../../../frontend` |
| `frontend_image_tag` | tag de la web | `local` |
| `deploy_frontend` | `false` omite la web del clúster | `true` |
| `log_level` | nivel de log | `INFO` |
| `jwt_key_revision` | revisión de la clave JWT local | `1` |

Terraform genera las contraseñas de PostgreSQL y la clave Ed25519 local. No se copian credenciales de producción.

### 6.2 Primer apply

```powershell
terraform init
terraform validate
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
kubectl --context docker-desktop --namespace sportapp-local get pods,jobs
curl.exe http://localhost:18080/health/ready
curl.exe http://localhost:18082/healthz
```

El ambiente está listo cuando los pods están `Running`, los Jobs están `Complete` y ambos endpoints responden `200`.

## 7. Actualizar backend y frontend

No es necesario reconstruir toda la infraestructura cuando cambia código de aplicación.

| Situación | Acción |
| --- | --- |
| Desarrollo activo de un servicio | ejecutarlo en el host contra PostgreSQL y Pub/Sub locales |
| Cambio sin migraciones | reconstruir con `local` y reiniciar el Deployment |
| Cambio con migraciones o varios componentes | construir con tag nuevo y aplicar Terraform |
| Cambio de manifiestos | actualizar el clon y aplicar Terraform |

Los componentes backend son `users-management`, `affiliation-management`, `complementary-services`, `training-management`, `events-management`, `third-party-management`, `bff-web` y `bff-mobile`.

### 7.1 Un componente sin migraciones

```powershell
cd ..\..\..\..\..\backend
py -3.13 -m uv run python scripts/task.py build users-management
kubectl --context docker-desktop --namespace sportapp-local rollout restart deployment/users-management
kubectl --context docker-desktop --namespace sportapp-local rollout status deployment/users-management
```

Reinicia también los workers asociados cuando corresponda. Este procedimiento no vuelve a ejecutar migraciones.

### 7.2 Cambios con migraciones

```powershell
cd ..\backend
$tag = "dev-" + (Get-Date -Format "yyyyMMdd-HHmm")
py -3.13 -m uv run python scripts/task.py build all --tag $tag

cd ..\platform\infra\terraform\environments\local
terraform plan -out=tfplan -var="backend_image_tag=$tag"
terraform show tfplan
terraform apply tfplan
kubectl --context docker-desktop --namespace sportapp-local get pods,jobs
```

El plan debe reemplazar los Jobs de migración y actualizar los Deployments. Para conservar el tag, escríbelo en `local.auto.tfvars`.

### 7.3 Frontend

```powershell
cd ..\frontend
docker build -t sportapp/web:local .
kubectl --context docker-desktop --namespace sportapp-local rollout restart deployment/web
kubectl --context docker-desktop --namespace sportapp-local rollout status deployment/web
```

Limpia imágenes antiguas cuando sea necesario con `docker image prune`, después de revisar qué capas se eliminarán.

## 8. Archivos locales y Git

| Archivo | ¿Git? | Contenido |
| --- | --- | --- |
| `*.tf`, `.terraform.lock.hcl`, `tests/*.tftest.hcl` | sí | código y versiones |
| `local.auto.tfvars.example` | sí | plantilla |
| `local.auto.tfvars` | no | rutas y tags locales |
| `terraform.tfstate*`, `tfplan*`, `.terraform/` | no | estado, planes y proveedores |

Antes de un commit revisa `git status --short` y `git diff --cached`.

## 9. Lista de verificación

- [ ] Docker Desktop usa WSL 2 y contenedores Linux.
- [ ] Kubernetes está en verde y fue creado con kubeadm.
- [ ] El nodo `docker-desktop` está `Ready` y usa runtime `docker://`.
- [ ] Existen las ocho imágenes del backend y la imagen web.
- [ ] `terraform validate` y `terraform plan` terminan sin errores.
- [ ] Los pods quedan `Running` y los Jobs `Complete`.
- [ ] El BFF responde `200` en `http://localhost:18080/health/ready`.
- [ ] La web responde `200` en `http://localhost:18082/healthz`.

## 10. Problemas frecuentes

| Síntoma | Causa | Solución |
| --- | --- | --- |
| No existe `docker-desktop` | Kubernetes no está activado | activa Kubernetes con kubeadm |
| `ErrImagePull` para `sportapp/*` | imagen ausente o clúster kind | construye la imagen y usa kubeadm |
| Kubernetes no inicia | estado interno corrupto | *Settings → Kubernetes → Reset Kubernetes cluster* |
| Terraform rechaza el contexto | no se usa `docker-desktop` | no cambies `kube_context` |
| Un Deployment agota 10 minutos | el pod no llega a Ready | revisa `describe`, eventos y logs del pod |

## 11. Pausar o eliminar el ambiente

| Objetivo | Acción | Qué se conserva |
| --- | --- | --- |
| Pausar la jornada | cerrar Docker Desktop | namespace, imágenes y datos |
| Eliminar el ambiente | `terraform destroy` en `environments/local` | las imágenes Docker; se pierden namespace y PostgreSQL |
| Reconstruir | `terraform apply` | crea base vacía y credenciales nuevas |

Antes de destruir, ejecuta `terraform plan -destroy` y verifica que la raíz activa sea exactamente `infra/terraform/environments/local`.

## Referencias oficiales

- [Docker Desktop: Kubernetes](https://docs.docker.com/desktop/use-desktop/kubernetes/)
- [HashiCorp: instalar Terraform](https://developer.hashicorp.com/terraform/install)
