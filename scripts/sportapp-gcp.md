# Uso de `sportapp-gcp.ps1`

[`sportapp-gcp.ps1`](sportapp-gcp.ps1) prepara SportApp en GCP. También apaga y enciende la parte costosa de producción sin perder la configuración fija.

Ejecuta, en orden, la [preparación de GCP](../docs/preparacion-terraform-gcp.md). Esa guía sigue siendo la referencia de cada paso.

El script siempre se ejecuta desde la estación del operador:

- Solo se completa a mano `platform\.env.ps1`.
- Los archivos de variables de Terraform los genera el script.
- Cada `apply` muestra el plan y pide confirmación.
- No crea llaves, no usa GitHub y no aprueba rollouts.

## Contenido

1. [Requisitos](#1-requisitos)
2. [Configurar `.env.ps1`](#2-configurar-envps1)
3. [Comandos](#3-comandos)
4. [Primera preparación](#4-primera-preparación)
5. [Apagar y encender producción](#5-apagar-y-encender-producción)
6. [Desplegar una release](#6-desplegar-una-release)
7. [Archivos que genera](#7-archivos-que-genera)
8. [Controles de seguridad](#8-controles-de-seguridad)
9. [Problemas frecuentes](#9-problemas-frecuentes)

## 1. Requisitos

| Herramienta | Instalación | Uso |
| --- | --- | --- |
| Terraform ≥ 1.11 | `winget install --id Hashicorp.Terraform -e` | obligatorio |
| Google Cloud CLI | `winget install --id Google.CloudSDK -e` | obligatorio; actualízalo con `gcloud components update` |
| Git | `winget install --id Git.Git -e` | obligatorio; descarga el submódulo `components/backend` |
| kubectl | `winget install --id Kubernetes.kubectl -e` | opcional, para revisar GKE a mano |

Además, la cuenta de `$operator` debe poder:

- crear proyectos;
- vincular la facturación;
- habilitar APIs.

Durante la primera preparación normalmente es la persona que crea los proyectos.

El script funciona en Windows PowerShell 5.1 y en PowerShell 7. Si PowerShell bloquea la ejecución de scripts, permítela solo en esa terminal:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

## 2. Configurar `.env.ps1`

Desde la carpeta `platform`, crea el archivo a partir de la plantilla, solo si todavía no existe:

```powershell
Copy-Item .env.example.ps1 .env.ps1
notepad .env.ps1
```

`.env.ps1` está ignorado por Git. Guarda solo identificadores y decisiones: nunca tokens, contraseñas, llaves JSON ni el contenido de una clave privada.

No hace falta cargarlo con `. .\.env.ps1`: el script lo lee solo.

### Obligatorias

| Variable | Ejemplo | Significado |
| --- | --- | --- |
| `$billing` | `"XXXXXX-XXXXXX-XXXXXX"` | cuenta de facturación (`gcloud billing accounts list`) |
| `$mgmt` | `"sportapp-mgmt-1234"` | ID del proyecto de gestión: estado, Cloud Build, Cloud Deploy |
| `$production` | `"sportapp-prod-1234"` | ID del proyecto de producción: GKE, Cloud SQL, Cloud Run |
| `$region` | `"us-central1"` | región; debe coincidir con `environments/production/terraform.tfvars` |
| `$operator` | `"usuario@dominio.com"` | persona que ejecuta Terraform; debe ser la cuenta activa de `gcloud` |
| `$budgetAmount` | `1000` | presupuesto mensual, sin comillas, en la moneda de la facturación |
| `$budgetCurrency` | `"USD"` | moneda de la cuenta de facturación (`USD`, `COP`...) |
| `$healthDataConsentVersion` | `"<versión aprobada>"` | versión vigente del consentimiento de datos de salud (ADR-034) |
| `$deployToolsImage` | `"gcr.io/...:588.0.0@sha256:<64 hex>"` | imagen por digest con `gcloud`, `kubectl` y `gke-gcloud-auth-plugin` |

### Opcionales

| Variable | Valor por defecto | Cuándo definirla |
| --- | --- | --- |
| `$budgetAlertAmounts` | avisos al 50 %, 90 % y 100 % | para avisos en montos absolutos, por ejemplo `@(50, 100, 250, 500)` |
| `$jwtPrivateKeyFile` | — | cuando el secreto `users-jwt-private-key` aún no tiene versión; ruta a una clave Ed25519 fuera del repositorio |
| `$approvers` | `@("user:$operator")` | si otra persona o un grupo aprueba los rollouts |
| `$alertEmails` | `@($operator)` | para enviar las alertas a otro correo o a un grupo |
| `$operators` | `@("user:$operator")` | si más personas pueden impersonar Terraform |
| `$releaseTriggersEnabled` | `$false` | `$true` cuando backend y frontend tengan `cloudbuild.release.yaml` en `main` |
| `$initialBackendVersion` / `$initialFrontendVersion` | la release más reciente | para fijar con qué release se crea Cloud Run la primera vez |

### Validar

```powershell
.\scripts\sportapp-gcp.ps1 check
```

`check` no cambia nada. Marca con `[falta]` cada variable ausente o inválida e imprime la línea exacta que debes agregar.

También revisa:

- las herramientas instaladas;
- los archivos versionados que necesita el script;
- las salidas del bootstrap;
- el estado de cada archivo de variables que generará;
- la cuenta de `gcloud` y las credenciales ADC;
- la conexión con GitHub.

| Opción | Efecto |
| --- | --- |
| `-Offline` | no consulta GCP; solo revisa herramientas, variables y archivos |
| `-Validate` | ejecuta además `terraform validate` en las cuatro raíces |
| `-ConfigFile <ruta.ps1>` | usa otro archivo de configuración |

Cuando todo está bien termina con `Todo listo`.

## 3. Comandos

```powershell
.\scripts\sportapp-gcp.ps1 <comando> [opciones]
```

| Comando | Qué hace | Cuándo usarlo |
| --- | --- | --- |
| `check` | valida sin cambiar nada | antes de cualquier otro comando |
| `setup` | preparación completa, fija y operativa | la primera vez; se puede repetir |
| `down` | destruye GKE, Cloud SQL y Cloud Run | al dejar de usar producción por días o semanas |
| `up` | recrea lo que destruyó `down` | al volver a usar producción |
| `status` | muestra qué recursos costosos existen | para confirmar que no quedó nada encendido |
| `promote` | ejecuta el trigger `promote-release` | para desplegar una release (sección 6) |
| `help` | muestra la ayuda | — |

| Opción | Comandos | Efecto |
| --- | --- | --- |
| `-AutoApprove` | `setup`, `up`, `down` | aplica los planes sin preguntar; no omite la confirmación del ID en `down` ni la de un plan que elimine recursos inesperados |
| `-ConfirmProject <id>` | `down` | confirma el ID del proyecto sin escribirlo |
| `-BackendVersion vX.Y.Z` | `promote` | release del backend |
| `-FrontendVersion vX.Y.Z` | `promote` | release del frontend; exige también `-BackendVersion` |
| `-ReleaseSuffix <sufijo>` | `promote` | de 1 a 8 minúsculas o dígitos, para volver a promover una versión ya publicada |

| Código de salida | Significado |
| --- | --- |
| `0` | terminó correctamente |
| `1` | error; nada se aplicó después del paso que falló |
| `2` | se detuvo en un paso manual; haz lo indicado y repite el comando |

## 4. Primera preparación

```powershell
.\scripts\sportapp-gcp.ps1 check
.\scripts\sportapp-gcp.ps1 setup
```

### Pasos de `setup`

| Paso | Qué hace | Qué revisar |
| --- | --- | --- |
| Estación | herramientas y autenticación; si faltan, abre `gcloud auth login` y `gcloud auth application-default login` | la cuenta activa es `$operator` |
| Proyectos | crea los proyectos que no existan y vincula la facturación | confirma la creación |
| APIs | habilita las APIs de arranque y crea los agentes de Cloud Build y Cloud Deploy | espera unos 90 s de propagación |
| Bootstrap | estado, cuentas `tf-*` y de entrega, presupuesto; respalda el estado local | plan sin destrucciones, salvo el retiro de WIF |
| Variables | genera los archivos de las otras raíces y comprueba la impersonación de `tf-apply-production` | reintenta solo mientras IAM se propaga |
| `production` | VPC, GKE, Cloud SQL, Pub/Sub, Artifact Registry, secretos y observabilidad | la primera vez tarda de 20 a 30 minutos |
| Secretos | carga `users-jwt-private-key` desde `$jwtPrivateKeyFile` si no tiene versión | — |
| `production-workloads` | descarga `components/backend` si falta y crea la base de Kubernetes | sin Deployments ni Jobs |
| `delivery` | conexión con GitHub, buckets de evidencia, triggers, pipelines y targets | — |
| Cloud Run | con la primera release, toma los digests de la evidencia y crea los servicios y sus targets | — |

### Pasos manuales

`setup` se detiene con el código de salida `2` y explica qué hacer. Al repetirlo continúa donde quedó.

1. **Autorizar la GitHub App** (una sola vez).
   1. Abre el enlace que muestra el script.
   2. Elige la región y la conexión `github`.
   3. Pulsa **Terminar la configuración**.
   4. Instala la app solo en `sport-app-backend`, `sport-app-frontend` y `sport-app-platform`.
   5. Presiona Enter en la terminal. Si prefieres continuar en otro momento, escribe `salir`.
2. **Habilitar los triggers de release.** Cuando backend y frontend tengan `cloudbuild.release.yaml` en `main`, agrega `$releaseTriggersEnabled = $true` en `.env.ps1` y repite `setup`.
3. **Publicar la primera release.**
   1. Crea un tag `vX.Y.Z` desde `main` en backend y en frontend ([manual de versionado](../docs/manual-versionado.md)).
   2. Espera a que `release-backend` y `release-frontend` terminen en `SUCCESS`.
   3. Repite `setup`.
4. **Clave JWT.** Si el secreto no tiene versión y no definiste `$jwtPrivateKeyFile`, genera la clave fuera del repositorio, defínela y repite `setup`:

   ```powershell
   & "C:\Program Files\Git\usr\bin\openssl.exe" genpkey -algorithm ed25519 -out C:\ruta-segura\sportapp-users-jwt.pem
   ```

Al final, `setup` muestra el comando `promote` para el primer despliegue (sección 6).

## 5. Apagar y encender producción

### Apagar

```powershell
.\scripts\sportapp-gcp.ps1 down
```

Antes de ejecutarlo:

- confirma en Cloud Deploy que no haya un rollout ni una migración en curso;
- exporta cualquier dato de Cloud SQL que necesites conservar.

| Elimina | Conserva |
| --- | --- |
| clúster GKE, nodos y todo lo que corre dentro | proyectos, facturación, estado, bootstrap e identidades |
| Cloud SQL, con **todos sus datos y respaldos** | Artifact Registry con sus imágenes |
| servicios Cloud Run | Secret Manager (incluida la clave JWT), red, Pub/Sub y observabilidad |
| permisos que dependen de lo anterior (`up` los recrea) | Cloud Build, Cloud Deploy, conexión con GitHub y aprobadores |

`down` sigue este orden:

1. Pide escribir el ID de `$production`.
2. Genera el plan de destrucción y aborta si alcanzaría algo de la columna «Conserva».
3. Guarda los digests desplegados en Cloud Run, para recrearlos con la última versión.
4. Retira la base de Kubernetes y espera a que GKE libere los balanceadores internos.
5. Quita la protección contra borrado solo de lo que se va a destruir.
6. Destruye y muestra `status`.

Para confirmar después que no quedó nada encendido:

```powershell
.\scripts\sportapp-gcp.ps1 status
```

Siguen existiendo costos menores: el almacenamiento de imágenes, los secretos, los logs y el estado. La destrucción completa de `environments/production` no la hace el script; es el procedimiento manual de la [sección 15.3](../docs/preparacion-terraform-gcp.md#153-destruir-solamente-el-plano-operativo).

### Encender

```powershell
.\scripts\sportapp-gcp.ps1 up
```

`up` hace lo siguiente:

1. recrea GKE, Cloud SQL y Cloud Run con los digests guardados;
2. aplica `production-workloads`;
3. reconcilia `delivery`, que recibe la conexión nueva de Cloud SQL.

GKE queda sin Deployments y Cloud SQL vacía. Termina con el comando para volver a promover la última release del backend: su etapa de migraciones recrea los esquemas.

```powershell
.\scripts\sportapp-gcp.ps1 promote -BackendVersion v1.2.0 -ReleaseSuffix 10181558
```

Copia el comando que imprime `up`. El sufijo evita repetir el nombre de una release que ya existe.

## 6. Desplegar una release

```powershell
.\scripts\sportapp-gcp.ps1 promote -BackendVersion v1.2.0 -FrontendVersion v0.9.0
```

- **Orden:** con ambas versiones, el script espera a que termine el promotor del backend antes de lanzar el del frontend, que se valida contra ese backend.
- **Aprobación:** el promotor solo crea releases; ningún rollout avanza sin aprobación humana. Apruébalos en Cloud Deploy en este orden:
  1. `production-gke-migrations`;
  2. promueve y aprueba `production-gke`;
  3. `bff-web`, `bff-mobile` y `frontend-web`.
- **Revisión:** antes de aprobar, revisa en cada release las anotaciones (commit, Cloud Build, contrato, sha256 de la evidencia) y los digests.

El rollback y las releases posteriores están en la [sección 14](../docs/preparacion-terraform-gcp.md#14-releases-posteriores-y-rollback) de la guía.

## 7. Archivos que genera

| Archivo | Contenido |
| --- | --- |
| `bootstrap/gcp-state/bootstrap.auto.tfvars` | proyectos, operadores, facturación y presupuesto |
| `environments/production/gcp.auto.tfvars` y `backend.hcl` | proyecto, impersonación, identidades de entrega, consentimiento y alertas |
| `environments/production/cloud-run-images.auto.tfvars.json` | digests de `web`, `bff-web` y `bff-mobile` |
| `environments/production-workloads/gcp.auto.tfvars` y `backend.hcl` | proyecto, región, bucket de estado e impersonación |
| `environments/delivery/gcp.auto.tfvars` y `backend.hcl` | identidades, aprobadores, imagen de herramientas, estado de la conexión y de los triggers |

Las rutas son relativas a `infra/terraform/`. Todos están ignorados por Git y empiezan con un encabezado que indica que los generó el script.

- **No los edites:** se regeneran en cada ejecución; los cambios se hacen en `.env.ps1`.
- **Archivos editados a mano:** antes de reemplazar uno sin ese encabezado, el script lo copia en `%USERPROFILE%\terraform-state-backups\sportapp\vars`.
- **Estado del bootstrap:** después de cada `apply` del bootstrap, el script guarda una copia del estado y su SHA256 en `%USERPROFILE%\terraform-state-backups\sportapp\state`.
- **Planes:** quedan como `tfplan-<paso>` en cada raíz. Para ver el detalle de uno:

  ```powershell
  terraform -chdir=<raíz> show tfplan-<paso>
  ```

## 8. Controles de seguridad

| Control | Comportamiento |
| --- | --- |
| Confirmación | cada `apply` se hace sobre un plan guardado, después de responder `si` |
| Recursos prohibidos | aborta si un plan crea `google_service_account_key`, recursos de Workload Identity Federation o Deployments y Jobs de Kubernetes |
| Eliminaciones inesperadas | pide confirmación aunque se use `-AutoApprove` |
| Bootstrap | solo acepta eliminaciones del retiro de WIF |
| Alcance de `down` | la lista de recursos que puede destruir está cerrada en el script; cualquier otra eliminación lo detiene |
| Credenciales | usa ADC del operador e impersona `tf-apply-production`; no guarda ni imprime tokens |
| Aprobaciones | `promote` nunca aprueba rollouts |

## 9. Problemas frecuentes

| Síntoma | Acción |
| --- | --- |
| `[falta] $... no está definida` | agrega en `.env.ps1` la línea que muestra `check` |
| `conserva el valor de ejemplo` | reemplaza el valor copiado de la plantilla |
| `region ... no coincide` | usa en `$region` la región de `environments/production/terraform.tfvars` |
| `la cuenta activa de gcloud es ...` | `gcloud config set account <operator>` o `gcloud auth login <operator>` |
| `faltan las credenciales de aplicación (ADC)` | `gcloud auth application-default login` |
| `No se pudo impersonar tf-apply-production` | confirma que `$operator` está en `operators` y que el bootstrap terminó; espera unos minutos y repite |
| `... debe ser un archivo .ps1` | `-ConfigFile` solo acepta archivos `.ps1` |
| `El plan crea recursos prohibidos` | no apliques; revisa el cambio de Terraform que lo provocó |
| `La destrucción alcanzaría recursos del plano que se conserva` | no se tocó nada; revisa el plan mostrado antes de volver a intentarlo |
| `siguen balanceadores de GKE` | revisa con `status` y elimina a mano los balanceadores huérfanos |
| `Faltan versiones en Secret Manager` | define `$jwtPrivateKeyFile` (sección 4) o carga el secreto con `gcloud secrets versions add` |
| `promote` falla porque la release ya existe | repite con `-ReleaseSuffix` |

Los demás errores de Terraform o GCP se explican en los [problemas frecuentes de la guía](../docs/preparacion-terraform-gcp.md#18-problemas-frecuentes).
