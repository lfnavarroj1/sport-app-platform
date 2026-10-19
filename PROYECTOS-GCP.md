# Proyectos de Google Cloud de SportApp

SportApp utiliza dos proyectos de Google Cloud porque la infraestructura de control y las cargas de la aplicación tienen ciclos de vida, permisos y costos diferentes.

## Resumen

| Proyecto | Variable utilizada | Función | Ciclo de vida |
| --- | --- | --- | --- |
| Gestión | `$mgmt` | Controla Terraform y el proceso de entrega | Fijo: se crea una vez y se conserva |
| Producción | `$production` | Ejecuta la aplicación y sus servicios | Operativo: sus recursos pueden destruirse y recrearse |

Desarrollo no requiere un tercer proyecto de GCP. Se ejecuta localmente mediante `infra/terraform/environments/local`.

## 1. Proyecto de gestión

Ejemplo de identificador:

```text
sportapp-mgmt-1234
```

El valor real se guarda localmente en la variable `$mgmt` y no debe escribirse en la documentación pública.

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

Ejemplo de identificador:

```text
sportapp-prod-1234
```

El valor real se guarda localmente en la variable `$production` y no debe escribirse en la documentación pública.

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
