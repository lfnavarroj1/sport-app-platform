# Menú único de SportApp (`scripts/sportapp.ps1`)

Un solo punto de entrada para desplegar en **local** o en **GCP** y lanzar **releases**. Es una capa delgada: GCP se delega en [`sportapp-gcp.ps1`](../scripts/sportapp-gcp.md) y los releases en [`sportapp-release.ps1`](../scripts/sportapp-release.md), invocados por parámetros; solo el flujo local, Strava y la tableta son propios.

```powershell
.\scripts\sportapp.ps1            # menú interactivo
.\scripts\sportapp.ps1 help       # ayuda
```

Requiere Windows PowerShell 5.1 o superior y se ejecuta desde la estación del operador, en el checkout principal de `platform` (el estado de Terraform local vive allí).

## Menú

| Opción | Contenido |
| --- | --- |
| 1. Local | prerrequisitos, construir imágenes `sportapp/*`, `terraform plan`/`apply`, Secret de Strava, activar Strava, estado y verificación, destruir |
| 2. GCP | `plan` (check -Validate), `status`, `images`, `setup`, `up`, `down`, `promote` |
| 3. Releases | `check`, `status`, `release`, `hotfix`, `builds`, `apk`, `submodules` |
| 4. Strava | secretos locales, activación y verificación ([guía de prueba](guia-prueba-strava.md)) |
| 5. Tableta | `adb reverse`, instalar el APK de depuración y `logcat`, solo en el dispositivo físico |
| 0. Salir | |

## Subcomandos no interactivos

Cada acción del menú tiene su equivalente `<área> <acción>`:

| Área | Acciones |
| --- | --- |
| `local` | `check`, `build`, `plan`, `apply`, `secrets`, `strava`, `status`, `destroy` |
| `gcp` | `plan`, `check`, `setup`, `up`, `down`, `status`, `images`, `promote` |
| `release` | `check`, `status`, `builds`, `release`, `hotfix`, `apk`, `submodules`, `prepare`, `keystore` |
| `strava` | `secrets`, `enable`, `status` |
| `tablet` | `check`, `reverse`, `install`, `logcat` |

```powershell
.\scripts\sportapp.ps1 local apply -Strava
.\scripts\sportapp.ps1 gcp promote -BackendVersion v1.2.0 -FrontendVersion v0.9.0
.\scripts\sportapp.ps1 release release -Target platform -Stories HU001,HU010
.\scripts\sportapp.ps1 release check -Target backend
```

Parámetros reenviados: `-Target`, `-Bump`, `-BackendVersion`, `-FrontendVersion`, `-MobileVersion`, `-PlatformVersion`, `-SystemVersion`, `-Stories`, `-Sprint`, `-ReleaseSuffix` y `-ConfigFile`. `-BackendPath`, `-FrontendPath` y `-MobilePath` cambian la ubicación de los componentes (por defecto, carpetas hermanas de `platform`).

## `-DryRun`

Con `-DryRun` se imprimen los comandos que se ejecutarían, sin ejecutarlos: no se llama a Terraform, Docker, kubectl, gcloud, adb ni a los scripts delegados, y no se piden secretos ni confirmaciones.

```powershell
.\scripts\sportapp.ps1 local apply -DryRun
```

## Reglas

- **Local y GCP separados.** Local usa solo el contexto `docker-desktop` (cada `kubectl` lo lleva explícito y se rechaza cualquier `gke_*`) y el emulador de Pub/Sub, que existe únicamente en local. GCP usa Cloud Deploy, Cloud Run, GKE y Pub/Sub administrado, nunca `docker-desktop`.
- **Confirmación escrita.** Toda acción que crea, cambia o destruye pide escribir `si`: construir imágenes, `apply`, `destroy`, crear el Secret, instalar el APK y, en GCP y releases, `setup`/`up`/`down`/`promote` y `release`/`hotfix`/`apk`/`submodules`/`prepare`/`keystore`. Nunca se reenvía `-AutoApprove`: los scripts delegados conservan sus propias confirmaciones y la aprobación humana de cada PR.
- **Nada automático.** Los `apply` se ejecutan sobre el plan mostrado y solo tras la confirmación.
- **Secretos.** Se escriben en la terminal (`Read-Host -AsSecureString`), viajan a `kubectl` como JSON por stdin y no se imprimen, no se guardan en archivos y no pasan por argumentos del proceso. La clave AES de 32 bytes (base64 url-safe) se genera en el momento; conserve el Secret, porque la clave no se vuelve a mostrar y reemplazarlo invalida los tokens cifrados.
- **Tableta.** Solo el dispositivo físico `R52NB04LMCB` (SM-T970): se exige que `adb devices` lo liste en estado `device`, todo `adb` lleva `-s R52NB04LMCB` y la compilación fija `ANDROID_SERIAL`. No se usan emuladores.

## Flujo local

1. Opción 1 → *Prerrequisitos*: Docker Desktop, contexto `docker-desktop`, Terraform, `uv` y backend en `develop`.
2. *Construir imágenes*: `uv run python scripts/task.py build all` (backend) y `docker build -t sportapp/web:local .` (frontend).
3. *Terraform apply*: `init`, `validate`, `plan -out=tfplan`, `show`, confirmación y `apply tfplan`.
4. Strava (opcional): *Cargar el Secret*, luego *Activar Strava* (`-var strava_integration_enabled=true`). Si Strava ya está desplegado, los planes posteriores añaden la variable solos para no desactivarlo.
5. *Estado y verificación*: pods y jobs, `/health/ready` de `bff-web` (18080) y `bff-mobile` (18081), `/healthz` de la web (18082), y tópicos y suscripciones del emulador de Pub/Sub.
6. *Destruir*: `plan -destroy`, confirmación y `apply`. Las imágenes Docker se conservan.

Detalles de cada paso: [Preparación local](preparacion-terraform-local.md).

## GCP

Antes de cualquier acción se muestran la cuenta y el proyecto de `gcloud` activos. `sportapp-gcp.ps1` no tiene un comando de solo plan: `plan` ejecuta `check -Validate` (no cambia nada) y `up`/`down` muestran su plan antes de aplicar. Configuración en `platform\.env.ps1` ([guía](../scripts/sportapp-gcp.md)).

## Pruebas

`tests/test_menu_sportapp.py` hace el análisis sintáctico del script (`ParseFile`), verifica las reglas anteriores sobre el código y ejecuta las acciones con `-DryRun`. Se omiten si no hay PowerShell. No se ejecuta ninguna acción real.
