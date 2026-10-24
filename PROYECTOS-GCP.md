# Proyectos de Google Cloud de SportApp

SportApp utiliza dos proyectos de Google Cloud porque la infraestructura de control y las cargas de la aplicación tienen ciclos de vida, permisos y costos diferentes.

## Resumen

| Proyecto | Variable utilizada | Función | Ciclo de vida |
| --- | --- | --- | --- |
| Gestión | `$mgmt` | Controla Terraform y el proceso de entrega | Fijo: se crea una vez y se conserva |
| Producción | `$production` | Ejecuta la aplicación y sus servicios | Operativo: sus recursos pueden destruirse y recrearse |

Desarrollo no requiere un tercer proyecto de GCP. Se ejecuta localmente mediante `infra/terraform/environments/local`.

## 1. Proyecto de gestión

Este documento no presupone ningún nombre concreto para el proyecto de gestión. Los nombres de ejemplo anteriores se eliminaron para evitar confundirlos con la configuración real.

En esta documentación, el proyecto de gestión se representa siempre como:

```text
<MANAGEMENT_PROJECT_ID>
```

El identificador real es el valor de `$mgmt` en el archivo local `platform/.env.ps1`. También corresponde a `management_project_id` dentro de `bootstrap.auto.tfvars` y `gcp.auto.tfvars` de `delivery`. El archivo `.env.ps1` está ignorado por Git para no publicar datos propios del entorno.

Este proyecto contiene el plano de control de la plataforma:

- buckets que almacenan el estado remoto de Terraform;
- cuentas `tf-plan-production` y `tf-apply-production`;
- cuentas separadas para construir, promover y desplegar;
- conexión de Cloud Build con GitHub;
- triggers de Cloud Build;
- buckets de evidencia de las releases;
- pipelines y targets de Cloud Deploy;
- permisos de los operadores y aprobadores.

El proyecto de gestión no ejecuta las cargas de SportApp ni contiene sus bases de datos.

### Por qué se conserva

Este proyecto permite destruir temporalmente la infraestructura costosa de producción sin perder:

- el estado de Terraform;
- las identidades y permisos de operación;
- la conexión autorizada con GitHub;
- la configuración de Cloud Build y Cloud Deploy;
- la evidencia histórica de las releases.

No se debe ejecutar `terraform destroy` en:

```text
infra/terraform/bootstrap/gcp-state
infra/terraform/environments/delivery
```

para apagar o eliminar las cargas de producción.

## 2. Proyecto de producción

En esta documentación, el proyecto de producción se representa siempre como:

```text
<PRODUCTION_PROJECT_ID>
```

El identificador real es el valor de `$production` en el archivo local `platform/.env.ps1`. También corresponde a `environments.production.project_id` en el bootstrap y a `project_id` en los archivos locales de `production` y `production-workloads`.

Este proyecto contiene el plano operativo de SportApp:

- VPC, subredes, firewall y conectividad privada;
- clúster GKE;
- servicios Cloud Run;
- instancia Cloud SQL y sus bases de datos;
- tópicos y suscripciones de Pub/Sub;
- repositorios de Artifact Registry;
- Secret Manager;
- cuentas de servicio de las cargas;
- monitoreo, alertas y registros de la aplicación.

Sus recursos son administrados principalmente por estas raíces:

```text
infra/terraform/environments/production
infra/terraform/environments/production-workloads
```

La primera crea la infraestructura de GCP. La segunda crea la base Kubernetes compartida dentro de GKE, como el namespace, los Services, las cuentas Kubernetes, el ConfigMap, los Secrets y el RBAC.

### Por qué puede recrearse

Los recursos de producción concentran la mayor parte del costo. Cuando el ambiente no se utilizará durante varios días o semanas, pueden destruirse de forma controlada y recrearse posteriormente usando el estado y las identidades conservadas en el proyecto de gestión.

El proyecto de producción y su vinculación de facturación se conservan. Lo que se destruye son los recursos administrados por `environments/production`.

Antes de destruirlos se deben respaldar los datos que deban conservarse. La destrucción puede eliminar bases de datos, secretos, imágenes y otros datos operativos.

## 3. Razones para separar los proyectos

### Seguridad

La separación impide que una identidad destinada a construir o desplegar aplicaciones obtenga control sobre toda la infraestructura.

- Los operadores humanos ejecutan Terraform mediante `tf-apply-production`.
- Cloud Build construye y publica imágenes, pero no aprovisiona infraestructura.
- Cloud Deploy actualiza cargas previamente autorizadas, pero no administra proyectos, facturación, redes o bases de datos.
- GitHub y GitHub Actions no reciben credenciales ni identidades de GCP.

### Ciclo de vida

El plano de control es estable, mientras que el plano operativo puede suspenderse, destruirse o recrearse. Si todo estuviera en un solo proyecto, una eliminación amplia podría borrar también el estado de Terraform y el mecanismo necesario para reconstruir el ambiente.

### Control de costos

La mayor parte del consumo corresponde a GKE, Cloud SQL, Cloud Run, red, almacenamiento e imágenes del proyecto de producción. Separarlos facilita identificar esos costos y eliminar los recursos operativos sin desmontar el proceso de administración.

El proyecto de gestión también puede generar costos, aunque normalmente menores. Los buckets de estado y evidencia, Cloud Build, registros y otros servicios deben seguir siendo monitoreados.

### Auditoría

Los cambios de infraestructura, las construcciones y los despliegues quedan separados:

```text
Operador autorizado
  → Terraform
  → proyectos de gestión y producción

Tag SemVer en GitHub
  → Cloud Build en gestión
  → imagen en Artifact Registry de producción
  → Cloud Deploy en gestión
  → aprobación humana
  → GKE o Cloud Run en producción
```

## 4. Relación entre los proyectos

Las identidades de entrega viven en el proyecto de gestión y reciben permisos limitados sobre recursos concretos del proyecto de producción.

| Identidad de gestión | Acceso permitido en producción |
| --- | --- |
| `cloud-build-backend` | publicar solamente en el repositorio de imágenes del backend |
| `cloud-build-frontend` | publicar solamente en el repositorio de imágenes del frontend |
| `release-promoter` | leer las imágenes y preparar releases en pipelines existentes |
| `cloud-deploy-execution` | leer imágenes y actualizar los destinos autorizados de GKE y Cloud Run |
| `tf-apply-production` | aplicar manualmente la infraestructura aprobada |

Ninguna cuenta de Cloud Build o Cloud Deploy puede impersonar `tf-apply-production`.

## 5. Facturación

Los dos proyectos se vinculan a una cuenta de facturación porque ambos pueden consumir servicios de Google Cloud:

```powershell
gcloud billing projects describe $mgmt
gcloud billing projects describe $production
```

Esto no significa que se pague dos veces por el mismo recurso. Cada servicio cobra su consumo en el proyecto donde está creado.

- Los costos del plano de control aparecen en el proyecto de gestión.
- Los costos de ejecución de SportApp aparecen en el proyecto de producción.

Los presupuestos y alertas sirven para avisar sobre el consumo, pero no detienen automáticamente los servicios.

## 6. Orden de creación

La preparación inicial se realiza en este orden:

1. Crear los proyectos de gestión y producción y vincularlos a facturación.
2. Aplicar `infra/terraform/bootstrap/gcp-state`.
3. Aplicar `infra/terraform/environments/production`.
4. Aplicar `infra/terraform/environments/production-workloads`.
5. Aplicar y autorizar `infra/terraform/environments/delivery`.
6. Habilitar las releases por tags SemVer.

Los comandos y archivos necesarios para ejecutar este orden se encuentran en [`docs/preparacion-terraform-gcp.md`](docs/preparacion-terraform-gcp.md).

## 7. Qué se conserva al apagar producción

| Se conserva | Se puede destruir y recrear |
| --- | --- |
| proyecto de gestión | GKE |
| proyecto de producción | Cloud SQL y sus datos, salvo respaldo externo |
| vinculación de facturación | servicios Cloud Run |
| buckets y estado de Terraform | Artifact Registry y sus imágenes |
| identidades e IAM del bootstrap | secretos operativos |
| conexión de Cloud Build con GitHub | Pub/Sub, red y observabilidad de producción |
| configuración de Cloud Build y Cloud Deploy | objetos Kubernetes del clúster eliminado |

La separación en dos proyectos existe para que el sistema de control y reconstrucción permanezca disponible incluso cuando la infraestructura operativa de SportApp se elimina para reducir costos.

## 8. Cómo se construye la infraestructura de los dos proyectos desde este repositorio

El repositorio `platform` contiene cuatro raíces Terraform independientes. Cada una tiene su propio estado y una responsabilidad diferente:

| Orden | Raíz Terraform | Proyecto principal | Qué construye |
| --- | --- | --- | --- |
| 1 | `infra/terraform/bootstrap/gcp-state` | gestión | estado remoto, identidades, permisos iniciales, APIs y presupuestos |
| 2 | `infra/terraform/environments/production` | producción | infraestructura de GCP donde funciona SportApp |
| 3 | `infra/terraform/environments/production-workloads` | producción | objetos base del clúster GKE |
| 4 | `infra/terraform/environments/delivery` | gestión | Cloud Build, conexión con GitHub, evidencia y Cloud Deploy |

La construcción no se ejecuta desde GitHub. Un operador autorizado realiza manualmente `plan` y `apply` desde su computadora.

### Referencia exacta del código

La siguiente tabla indica dónde está implementada cada parte. Los archivos `.example` contienen la forma de la configuración local, pero Terraform utiliza los archivos reales copiados desde ellos.

| Parte | Archivo principal | Archivos relacionados |
| --- | --- | --- |
| creación manual de los proyectos y facturación | no existe como recurso Terraform; se realiza con `gcloud` siguiendo [la preparación de GCP](docs/preparacion-terraform-gcp.md#5-crear-proyectos-y-autenticarse) | variables locales en `.env.ps1`, explicadas en [Definir identificadores](docs/preparacion-terraform-gcp.md#4-definir-identificadores) |
| bootstrap del proyecto de gestión | [`infra/terraform/bootstrap/gcp-state/main.tf`](infra/terraform/bootstrap/gcp-state/main.tf) | [`variables.tf`](infra/terraform/bootstrap/gcp-state/variables.tf), [`outputs.tf`](infra/terraform/bootstrap/gcp-state/outputs.tf), [`versions.tf`](infra/terraform/bootstrap/gcp-state/versions.tf) y [`bootstrap.auto.tfvars.example`](infra/terraform/bootstrap/gcp-state/bootstrap.auto.tfvars.example) |
| entrada de la infraestructura de producción | [`infra/terraform/environments/production/main.tf`](infra/terraform/environments/production/main.tf) | [`variables.tf`](infra/terraform/environments/production/variables.tf), [`terraform.tfvars`](infra/terraform/environments/production/terraform.tfvars), [`outputs.tf`](infra/terraform/environments/production/outputs.tf), [`gcp.auto.tfvars.example`](infra/terraform/environments/production/gcp.auto.tfvars.example) y [`backend.hcl.example`](infra/terraform/environments/production/backend.hcl.example) |
| recursos internos de producción | [`infra/terraform/modules/gcp/platform/main.tf`](infra/terraform/modules/gcp/platform/main.tf) | módulos de [`infra/terraform/modules/gcp`](infra/terraform/modules/gcp) para red, GKE, IAM, Artifact Registry, Cloud SQL, Pub/Sub, Cloud Run y observabilidad |
| base Kubernetes de GKE | [`infra/terraform/environments/production-workloads/main.tf`](infra/terraform/environments/production-workloads/main.tf) | [`providers.tf`](infra/terraform/environments/production-workloads/providers.tf), [`variables.tf`](infra/terraform/environments/production-workloads/variables.tf), [`gcp.auto.tfvars.example`](infra/terraform/environments/production-workloads/gcp.auto.tfvars.example) y [`backend.hcl.example`](infra/terraform/environments/production-workloads/backend.hcl.example) |
| Cloud Build y Cloud Deploy | [`infra/terraform/environments/delivery/main.tf`](infra/terraform/environments/delivery/main.tf) | [`variables.tf`](infra/terraform/environments/delivery/variables.tf), [`outputs.tf`](infra/terraform/environments/delivery/outputs.tf), [`gcp.auto.tfvars.example`](infra/terraform/environments/delivery/gcp.auto.tfvars.example) y [`backend.hcl.example`](infra/terraform/environments/delivery/backend.hcl.example) |
| manifiestos y verificaciones de Cloud Deploy | [`deploy/clouddeploy`](deploy/clouddeploy) | [`allowlist.json`](deploy/clouddeploy/allowlist.json), configuración de [GKE](deploy/clouddeploy/gke) y plantillas de [Cloud Run](deploy/clouddeploy/cloudrun) |
| promoción de releases | [`cloudbuild.promote.yaml`](cloudbuild.promote.yaml) | [`scripts/promote_release.py`](scripts/promote_release.py) y [`release-manifest.yaml`](release-manifest.yaml) |

Dentro de los archivos principales, las referencias más importantes son:

| Implementación | Referencia |
| --- | --- |
| APIs del proyecto de gestión | [`bootstrap/gcp-state/main.tf`, recurso `google_project_service.management`](infra/terraform/bootstrap/gcp-state/main.tf#L103) |
| bucket del estado remoto | [`bootstrap/gcp-state/main.tf`, recurso `google_storage_bucket.state`](infra/terraform/bootstrap/gcp-state/main.tf#L136) |
| cuentas `tf-plan` y `tf-apply` | [`bootstrap/gcp-state/main.tf`](infra/terraform/bootstrap/gcp-state/main.tf#L181) |
| identidades de Cloud Build y Cloud Deploy | [`bootstrap/gcp-state/main.tf`, recurso `google_service_account.delivery`](infra/terraform/bootstrap/gcp-state/main.tf#L267) |
| composición de toda la infraestructura productiva | [`modules/gcp/platform/main.tf`](infra/terraform/modules/gcp/platform/main.tf#L195) |
| namespace, ConfigMap, Secrets, Services y RBAC de GKE | [`production-workloads/main.tf`](infra/terraform/environments/production-workloads/main.tf#L48) |
| conexión de Cloud Build con GitHub | [`delivery/main.tf`, recurso `google_cloudbuildv2_connection.github`](infra/terraform/environments/delivery/main.tf#L289) |
| triggers de release | [`delivery/main.tf`, recurso `google_cloudbuild_trigger.release`](infra/terraform/environments/delivery/main.tf#L333) |
| targets de GKE y Cloud Run | [`delivery/main.tf`](infra/terraform/environments/delivery/main.tf#L392) |
| pipelines de Cloud Deploy | [`delivery/main.tf`, recurso `google_clouddeploy_delivery_pipeline.this`](infra/terraform/environments/delivery/main.tf#L455) |

```text
Estación del operador
  |
  +-- bootstrap/gcp-state ----------> proyecto de gestión
  |                                    estado, cuentas e IAM
  |
  +-- environments/production -----> proyecto de producción
  |                                    red, GKE, SQL y servicios
  |
  +-- production-workloads --------> GKE de producción
  |                                    namespace y base Kubernetes
  |
  +-- environments/delivery -------> proyecto de gestión
                                       Cloud Build y Cloud Deploy
```

### 8.1 Los proyectos se crean antes de ejecutar Terraform

En el diseño actual, Terraform no crea los dos proyectos de GCP. El operador los crea una sola vez y los vincula con la cuenta de facturación. Terraform recibe sus identificadores y construye los recursos dentro de ellos.

Esto se comprueba en el código del bootstrap: [`data.google_project.management`](infra/terraform/bootstrap/gcp-state/main.tf#L99) y [`data.google_project.environment`](infra/terraform/bootstrap/gcp-state/main.tf#L357) son fuentes de datos que leen proyectos existentes. No hay un recurso `google_project` que los cree.

**Directorio de ejecución:** raíz `platform`.

```powershell
. .\.env.ps1

gcloud auth login
gcloud auth application-default login

gcloud projects create $mgmt --name="SportApp gestion"
gcloud projects create $production --name="SportApp produccion"

gcloud billing projects link $mgmt --billing-account=$billing
gcloud billing projects link $production --billing-account=$billing
```

Las variables provienen del archivo local `platform/.env.ps1`:

| Variable | Contenido |
| --- | --- |
| `$mgmt` | identificador del proyecto de gestión |
| `$production` | identificador del proyecto de producción |
| `$billing` | identificador de la cuenta de facturación |
| `$region` | región principal de los recursos |
| `$operator` | cuenta humana autorizada para Terraform |

Si los proyectos ya existen, no vuelvas a ejecutar `gcloud projects create`. Comprueba solamente que los valores sean correctos:

```powershell
gcloud projects describe $mgmt
gcloud projects describe $production
gcloud billing projects describe $mgmt
gcloud billing projects describe $production
```

### 8.2 Primera etapa: construir el plano de gestión

La primera raíz que se aplica es:

```text
platform/infra/terraform/bootstrap/gcp-state
```

Antes del primer plan, el operador habilita manualmente las APIs mínimas indicadas en la guía de preparación. Esto es necesario porque Terraform todavía no tiene estado, cuentas de servicio ni permisos para hacerlo por sí mismo.

**Archivo de entrada local:** `bootstrap.auto.tfvars`, creado a partir de `bootstrap.auto.tfvars.example`.

Este archivo relaciona los dos proyectos:

```hcl
management_project_id = "<PROYECTO_DE_GESTION>"
region                = "us-central1"

environments = {
  production = {
    project_id           = "<PROYECTO_DE_PRODUCCION>"
    operators            = ["user:<CORREO_DEL_OPERADOR>"]
    budget_amount        = 300
    budget_alert_amounts = [50, 100, 300]
    delivery             = true
  }
}

billing_account = "<CUENTA_DE_FACTURACION>"
budget_currency = "USD"
```

**Directorio de ejecución:** `platform/infra/terraform/bootstrap/gcp-state`.

```powershell
if (-not (Test-Path bootstrap.auto.tfvars)) {
  Copy-Item bootstrap.auto.tfvars.example bootstrap.auto.tfvars
}

terraform init
terraform validate
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
terraform output
```

Este `apply` construye principalmente en el proyecto de gestión:

- buckets de estado Terraform;
- cuentas `tf-plan-production` y `tf-apply-production`;
- cuentas `cloud-build-backend` y `cloud-build-frontend`;
- cuentas `release-promoter` y `cloud-deploy-execution`;
- bindings IAM para los operadores;
- APIs del plano de entrega;
- presupuesto y alertas configuradas.

El bootstrap también habilita servicios y prepara permisos iniciales necesarios en el proyecto de producción. No crea todavía GKE, Cloud SQL, Cloud Run ni la red de producción.

Las salidas importantes son:

```powershell
terraform output state_buckets
terraform output apply_service_accounts
terraform output delivery_identities
```

Estas salidas se copian en los archivos locales de las siguientes raíces. No se inventan ni se consultan en un `gcp.auto.tfvars` vacío.

### 8.3 Segunda etapa: construir la infraestructura de producción

La segunda raíz es:

```text
platform/infra/terraform/environments/production
```

Antes de ejecutar Terraform se crean, en ese mismo directorio:

- `gcp.auto.tfvars`, a partir de `gcp.auto.tfvars.example`;
- `backend.hcl`, a partir de `backend.hcl.example`.

Sus valores provienen de `$production` y de las salidas del bootstrap:

| Campo | Fuente |
| --- | --- |
| `project_id` | `$production` |
| `impersonate_service_account` | `apply_service_accounts.production` |
| `delivery_identities` | salida completa `delivery_identities` |
| `bucket` de `backend.hcl` | `state_buckets.production` |
| cuenta de `backend.hcl` | `apply_service_accounts.production` |

**Directorio de ejecución:** `platform/infra/terraform/environments/production`.

```powershell
if (-not (Test-Path gcp.auto.tfvars)) {
  Copy-Item gcp.auto.tfvars.example gcp.auto.tfvars
}
if (-not (Test-Path backend.hcl)) {
  Copy-Item backend.hcl.example backend.hcl
}

terraform init "-backend-config=backend.hcl" -reconfigure
terraform validate
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
```

Este `apply` construye dentro del proyecto de producción:

- VPC, subredes, NAT y conectividad privada;
- GKE;
- Cloud SQL;
- Pub/Sub;
- Artifact Registry;
- Secret Manager;
- cuentas de servicio de las cargas;
- monitoreo y alertas;
- permisos cruzados mínimos para las identidades del proyecto de gestión.

En la primera aplicación, `cloud_run_images` permanece vacío. Por eso todavía no se crean los servicios Cloud Run. Primero se deben construir las imágenes aprobadas mediante Cloud Build.

Solo después de un `apply` exitoso se consultan sus salidas:

```powershell
terraform output artifact_registry_urls
terraform output gke
terraform output app_secret_ids
```

Estos comandos se ejecutan desde `environments/production`, no desde `delivery` ni desde el bootstrap.

### 8.4 Tercera etapa: construir la base Kubernetes

La tercera raíz es:

```text
platform/infra/terraform/environments/production-workloads
```

Esta raíz lee el estado de `production` y se conecta al clúster GKE que acaba de ser creado.

Antes de aplicarla deben existir:

- el clúster GKE;
- las versiones de los secretos requeridos;
- el submódulo `platform/components/backend` con `deploy/k8s/base`;
- su propio `gcp.auto.tfvars` y `backend.hcl` completos.

**Directorio de ejecución:** `platform/infra/terraform/environments/production-workloads`.

```powershell
terraform init "-backend-config=backend.hcl" -reconfigure
terraform validate
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
```

Este `apply` crea dentro de GKE:

- namespace `sportapp`;
- cuentas de servicio Kubernetes;
- ConfigMap compartido;
- Secrets requeridos por las cargas;
- Services internos;
- Role y RoleBinding de Cloud Deploy.

No crea Deployments ni Jobs de migración. Esas cargas pertenecen a Cloud Deploy para evitar que Terraform revierta una release.

### 8.5 Cuarta etapa: construir el plano de entrega

La cuarta raíz es:

```text
platform/infra/terraform/environments/delivery
```

Aunque se aplica al final, sus recursos se crean principalmente en el proyecto de gestión. Esta raíz lee las salidas de `production` para conocer GKE, Artifact Registry y los servicios Cloud Run disponibles.

Sus archivos locales son:

- `gcp.auto.tfvars`, creado desde `gcp.auto.tfvars.example`;
- `backend.hcl`, creado desde `backend.hcl.example`.

El primer apply se ejecuta con:

```hcl
github_connection_ready  = false
release_triggers_enabled = false
```

**Directorio de ejecución:** `platform/infra/terraform/environments/delivery`.

```powershell
terraform init "-backend-config=backend.hcl" -reconfigure
terraform validate
terraform plan -out=tfplan-connection
terraform show tfplan-connection
terraform apply tfplan-connection
```

Este primer apply crea la conexión de Cloud Build con GitHub, todavía pendiente de autorización. El operador termina manualmente la configuración en la consola de GCP y autoriza solamente los repositorios de backend, frontend y plataforma.

Cuando la conexión muestra `COMPLETE`, se cambia:

```hcl
github_connection_ready  = true
release_triggers_enabled = false
```

Un segundo plan y apply crea los repositorios vinculados y los triggers deshabilitados. Finalmente, cuando `cloudbuild.release.yaml` existe en `main` de backend y frontend, se cambia:

```hcl
release_triggers_enabled = true
```

Un tercer plan y apply habilita los triggers de releases SemVer.

Esta raíz construye en el proyecto de gestión:

- conexión y repositorios de Cloud Build;
- triggers de backend y frontend;
- trigger manual de promoción;
- buckets de evidencia;
- pipelines y targets de Cloud Deploy;
- permisos de aprobadores y cuentas de ejecución.

### 8.6 Creación inicial de Cloud Run

Después de habilitar los triggers, se publica un tag SemVer en backend y frontend. Cloud Build construye y publica las imágenes en Artifact Registry del proyecto de producción.

Los digests generados para `web`, `bff-web` y `bff-mobile` se agregan a `cloud_run_images` en el archivo local de `environments/production`. Desde ese directorio se genera y aplica un nuevo plan:

```powershell
terraform plan -out=tfplan-cloud-run-initial
terraform show tfplan-cloud-run-initial
terraform apply tfplan-cloud-run-initial
```

Este apply crea la primera revisión de los servicios Cloud Run. Después se aplica nuevamente `environments/delivery` para registrar sus targets de Cloud Deploy.

A partir de ese momento, Terraform conserva la configuración de infraestructura, pero las nuevas imágenes se despliegan mediante Cloud Deploy con aprobación humana.

### 8.7 Resultado final

Cuando las cuatro raíces han sido aplicadas, la distribución queda así:

| Recurso | Proyecto de gestión | Proyecto de producción |
| --- | :---: | :---: |
| estado remoto Terraform | sí | no |
| cuentas `tf-plan` y `tf-apply` | sí | no |
| Cloud Build y conexión con GitHub | sí | no |
| Cloud Deploy, pipelines y evidencia | sí | no |
| VPC y conectividad privada | no | sí |
| GKE y objetos Kubernetes | no | sí |
| Cloud SQL | no | sí |
| Cloud Run | no | sí |
| Artifact Registry | no | sí |
| Pub/Sub y Secret Manager de la aplicación | no | sí |

### 8.8 Cambios posteriores

El procedimiento depende del tipo de cambio:

| Cambio | Procedimiento |
| --- | --- |
| red, IAM, GKE, Cloud SQL, Pub/Sub o configuración compartida | plan y apply manual de la raíz Terraform propietaria |
| namespace, Services, ConfigMap, KSA, Secrets o RBAC de GKE | plan y apply manual de `production-workloads` |
| conexión, triggers, pipelines o targets | plan y apply manual de `delivery` |
| código o imagen del backend/frontend | tag SemVer, Cloud Build y Cloud Deploy; Terraform no participa |

La secuencia detallada, las APIs previas, la preparación de archivos y la solución de errores están documentadas en [`docs/preparacion-terraform-gcp.md`](docs/preparacion-terraform-gcp.md).
