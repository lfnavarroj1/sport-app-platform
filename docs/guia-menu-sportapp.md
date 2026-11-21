# Menú único de SportApp (`scripts/sportapp.ps1`)

Un solo punto de entrada con tres opciones: integrar Strava paso a paso, lanzar releases y desplegar o actualizar la versión actual en **local** o en **GCP**. Es una capa delgada: GCP se delega en [`sportapp-gcp.ps1`](../scripts/sportapp-gcp.md) y los releases en [`sportapp-release.ps1`](../scripts/sportapp-release.md), invocados por parámetros; solo el flujo local, el asistente de Strava y la tableta son propios.

```powershell
.\scripts\sportapp.ps1            # menú interactivo
.\scripts\sportapp.ps1 help       # ayuda
```

Requiere Windows PowerShell 5.1 o superior y se ejecuta desde la estación del operador, en el checkout principal de `platform` (el estado de Terraform local vive allí).

## Menú

| Opción | Contenido |
| --- | --- |
| 1. Integración con Strava | asistente guiado de cinco pasos más tabla de fallos; pregunta Local o GCP al inicio |
| 2. Lanzar releases | secuencia automatizada y comandos sueltos de `sportapp-release.ps1` |
| 3. Desplegar y actualizar | Local o GCP: construir, plan/apply, actualizar imágenes (local); estado, imágenes, up, promote, down (GCP) |
| 0. Salir | |

## Subcomandos no interactivos

| Comando | Acciones |
| --- | --- |
| `strava -Environment local\|gcp [-FromStep n]` | asistente de Strava (paso 1 a 6) |
| `release sequence -Target <componente>` | secuencia completa; `check`, `status`, `builds`, `release`, `hotfix`, `apk`, `submodules`, `prepare`, `keystore` como comandos sueltos |
| `deploy -Environment local <acción>` | `check`, `build`, `plan`, `apply`, `update` (con `-Component`) |
| `deploy -Environment gcp <acción>` | `plan`, `status`, `images`, `up`, `promote`, `down` |

```powershell
.\scripts\sportapp.ps1 strava -Environment gcp
.\scripts\sportapp.ps1 release sequence -Target backend -Bump patch
.\scripts\sportapp.ps1 deploy update -Environment local -Component bff-mobile
.\scripts\sportapp.ps1 deploy promote -Environment gcp -BackendVersion v1.2.0 -FrontendVersion v0.9.0
```

Parámetros reenviados: `-Target`, `-Bump`, `-BackendVersion`, `-FrontendVersion`, `-MobileVersion`, `-PlatformVersion`, `-SystemVersion`, `-Stories`, `-Sprint`, `-ReleaseSuffix` y `-ConfigFile`. `-BackendPath`, `-FrontendPath` y `-MobilePath` cambian la ubicación de los componentes (por defecto, carpetas hermanas de `platform`).

## 1. Asistente de Strava

Basado en [guia-prueba-strava.md](guia-prueba-strava.md). En cada paso muestra **qué** hacer, **dónde** (URL o comando), **qué valores** escribir campo por campo, **cómo saber que salió bien** y **qué hacer si falla**, y espera: `Enter` continúa, `r` repite el paso, `a` muestra la ayuda de fallos y `s` sale (se retoma con `-FromStep n`). Solo abre el navegador si respondes `si`.

| Paso | Local | GCP |
| --- | --- | --- |
| 1. Crear la aplicación | `strava.com/settings/api`, dominio de callback `localhost` | igual; el dominio de `bff-mobile` se lee de `terraform output runtime_config` de production |
| 2. Cargar secretos | Secret `sportapp-third-party` por stdin (`kubectl`, contexto `docker-desktop`) | `gcloud secrets versions add` de `strava-client-id`, `strava-client-secret`, `strava-token-key` por stdin |
| 3. Activar | `terraform apply -var strava_integration_enabled=true` | `terraform apply -var sync_strava_secret=true` en `production-workloads` |
| 4. Tableta | `adb reverse tcp:18081`, APK contra `http://localhost:18081/`, vincular | APK contra la URL de `bff-mobile` en Cloud Run, vincular |
| 5. Sincronizar | conteos en PostgreSQL, `source = STRAVA`, estado | suscripción de Pub/Sub, servicios de Cloud Run, `status` de GCP |
| 6. Si algo falla | tabla de síntomas, causas y acciones (plan B con túnel HTTPS, `INVALID_STATE`, 0 actividades, `third-party-management 0/1`) | igual |

Los textos del asistente están en el bloque `$StravaSteps` y `$StravaTroubleshooting` de `scripts/sportapp.ps1`, separados de la lógica, para editarlos sin tocar el código.

Notas de GCP: `sportapp-gcp.ps1` no expone `sync_strava_secret`, así que el paso 3 ejecuta Terraform directamente sobre `production-workloads` (ya inicializada por `sportapp-gcp.ps1 up` o `check`), mostrando el plan y pidiendo `si`; un `up` posterior reconcilia sin la variable, por lo que hay que repetir el paso. Verificar los pods de GKE y `source = STRAVA` en Cloud SQL queda como consulta manual (guía, sección 7).

## 2. Lanzar releases

`release sequence` ejecuta de corrido, con **una confirmación `si` por etapa**:

1. `check` del componente y de la plataforma (solo lectura);
2. `release` del componente con `-SkipPlatform`;
3. `submodules`: mueve `components/*` a los tags publicados y actualiza `release-manifest.yaml`;
4. `release` de la plataforma (`release/vX.Y.Z`, manifiesto `released`, tag y retorno a `develop`).

Dentro de una etapa se pasa `-AutoApprove` a `sportapp-release.ps1` (confirmaciones de rutina); la aprobación de cada PR sigue siendo humana porque ese script siempre la pregunta. Componentes: `backend`, `backend-frontend`, `frontend` y `mobile` (el APK se compila al final de la release móvil). El despliegue posterior se hace con la opción 3.

## 3. Desplegar y actualizar

**Local** (contexto `docker-desktop`, nunca `gke_*`; el emulador de Pub/Sub existe solo aquí):

- `check`: Docker, kubectl, Terraform, `uv` y backend en `develop`.
- `build`: `uv run python scripts/task.py build all` (backend) y `docker build -t sportapp/web:local .`.
- `plan` y `apply`: `init`, `validate`, `plan -out=tfplan`, `show`, confirmación y `apply tfplan`. Si Strava ya está desplegado, se añade la variable para no desactivarlo.
- `update`: reconstruye (`-Component all`, `web` o un servicio), `rollout restart` y verificación (`kubectl wait` o `rollout status`, pods, jobs, health de `bff-web`, `bff-mobile` y web, tópicos y suscripciones). Sin migraciones; con migraciones o cambios de manifiestos use `apply` con un tag nuevo ([guía local](preparacion-terraform-local.md), sección 7).

**GCP** (Cloud Deploy, Cloud Run, GKE y Pub/Sub administrado; nunca `docker-desktop`): antes de actuar se muestran la cuenta y el proyecto de `gcloud` activos. `plan` ejecuta `check -Validate` (`sportapp-gcp.ps1` no tiene un plan aislado; `up` y `down` muestran su plan antes de aplicar), `status`, `images`, `up`, `promote` (desplegar o actualizar una release o promover versiones/digests nuevos) y `down`.

## Reglas

- **Confirmación escrita.** Toda acción que crea, cambia o destruye pide escribir `si`. En GCP nunca se reenvía `-AutoApprove`.
- **Nada automático.** Los `apply` se ejecutan sobre el plan mostrado y solo tras la confirmación.
- **Secretos.** Se escriben en la terminal (`Read-Host -AsSecureString`) y viajan por stdin; no se imprimen, no se guardan en archivos ni pasan por argumentos. La clave AES de 32 bytes (base64 url-safe) se genera en el momento y no se vuelve a mostrar; reemplazar el Secret invalida los tokens cifrados.
- **Tableta.** Solo el dispositivo físico `R52NB04LMCB` (SM-T970): `adb devices` debe listarlo en estado `device`, todo `adb` lleva `-s R52NB04LMCB` y la compilación fija `ANDROID_SERIAL`. No se usan emuladores.

## `-DryRun` y pruebas

Con `-DryRun` se imprimen los comandos sin ejecutarlos: no se llama a Terraform, Docker, kubectl, gcloud, adb ni a los scripts delegados, y no se piden secretos ni confirmaciones. `-SimulatedInput` (solo con `-DryRun`) aporta respuestas separadas por comas (`<enter>` es Enter) para recorrer menús y asistente:

```powershell
.\scripts\sportapp.ps1 strava -Environment local -DryRun -SimulatedInput "no,<enter>,<enter>,<enter>,<enter>,<enter>,<enter>,<enter>"
```

`tests/test_menu_sportapp.py` hace el análisis sintáctico (`ParseFile`), verifica las reglas sobre el código y recorre el asistente, la secuencia de releases y el despliegue con `-DryRun`. Se omiten las pruebas de ejecución si no hay PowerShell. No se ejecuta ninguna acción real.
