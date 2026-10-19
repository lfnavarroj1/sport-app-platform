# Uso de `sportapp-release.ps1`

[`sportapp-release.ps1`](sportapp-release.ps1) publica la release de **backend y frontend** desde la estación del operador. Son los dos componentes que se despliegan en GCP. Para cada repositorio con cambios ejecuta, en orden:

1. crea o reutiliza el pull request `develop` → `main`;
2. espera a que terminen sus pruebas;
3. pide la aprobación en la terminal y fusiona;
4. crea la GitHub Release `vX.Y.Z` sobre el commit de merge;
5. espera el workflow de validación de la release;
6. espera los builds de Cloud Build que dispara cada tag (`release-backend` y `release-frontend`) y, si fallan, muestra el paso y el error;
7. mueve los submódulos `components/backend` y `components/frontend` de la plataforma a los tags con imágenes publicadas y actualiza `release-manifest.yaml`.

El script usa tu sesión de GitHub CLI y, para seguir Cloud Build, tu `gcloud` en modo lectura. No crea credenciales en GitHub ni despliega.

Cada tag que crea también inicia en GCP, si están habilitados, los triggers de Cloud Build `release-backend` y `release-frontend`. El despliegue posterior se hace con [`sportapp-gcp.ps1 promote`](sportapp-gcp.md#6-desplegar-una-release).

La **aplicación móvil** se publica aparte con [`sportapp-release-movil.ps1`](sportapp-release-movil.md): no tiene imagen ni pasa por Cloud Build o Cloud Deploy, así que no influye en los despliegues. Los dos scripts comparten el código común en [`sportapp-release-common.ps1`](sportapp-release-common.ps1).

## Contenido

1. [Requisitos](#1-requisitos)
2. [Configuración](#2-configuración)
3. [Preparación única](#3-preparación-única)
4. [Publicar una release](#4-publicar-una-release)
5. [Aprobación de los PR](#5-aprobación-de-los-pr)
6. [Versiones](#6-versiones)
7. [Submódulos y manifiesto de la plataforma](#7-submódulos-y-manifiesto-de-la-plataforma)
8. [Comandos y opciones](#8-comandos-y-opciones)
9. [Problemas frecuentes](#9-problemas-frecuentes)

## 1. Requisitos

| Herramienta | Para qué | Instalación |
| --- | --- | --- |
| GitHub CLI (`gh`) con sesión iniciada | PR, merge y releases | `winget install --id GitHub.cli -e` y `gh auth login` |
| Git | clon local del frontend (preparación) y submódulos de la plataforma | `winget install --id Git.Git -e` |
| Google Cloud CLI con la cuenta del operador | consultar los builds de Cloud Build en el proyecto de gestión (fase 6) | la misma de `sportapp-gcp.ps1`; sin ella la fase se omite con un aviso |

Tu cuenta debe ser administradora del backend y del frontend, o tener permiso de escritura y una cuenta revisora (sección 5).

Para comprobarlo:

```powershell
.\scripts\sportapp-release.ps1 check
```

## 2. Configuración

El script lee `platform\.env.ps1`, el mismo archivo de [`sportapp-gcp.ps1`](sportapp-gcp.md#2-configurar-envps1). Todas las variables son opcionales; la plantilla es [`.env.example.ps1`](../.env.example.ps1).

| Variable | Valor por defecto | Uso |
| --- | --- | --- |
| `$githubOwner` | `lfnavarroj1` | dueño de los repositorios |
| `$releaseReviewer` | — | cuenta de GitHub de un compañero que aprueba los PR |
| `$frontendRepoPath` | `..\frontend` | clon local del frontend, para `prepare` |
| `$mgmt`, `$region` | los de `sportapp-gcp.ps1` | proyecto y región de Cloud Build (fase 6) |

Nunca guardes tokens en `.env.ps1`.

## 3. Preparación única

Los workflows de release (`release-validation` en el backend y `release-web` en el frontend) exigen que el commit del tag esté en `main`. Hoy el frontend no tiene `main`. Para crearla:

```powershell
.\scripts\sportapp-release.ps1 prepare
```

Crea `main` en el primer commit de `develop`, para que el primer PR muestre todo el historial. Después, protege `main` en el frontend como en el backend (*Settings → Rules*: PR obligatorio y una aprobación).

Antes de la primera release, `cloudbuild.release.yaml` debe estar en `develop` de los dos repositorios. Al fusionarse llega a `main` y Cloud Build lo lee desde el commit del tag.

## 4. Publicar una release

```powershell
.\scripts\sportapp-release.ps1 status    # qué tiene develop que main no tiene
.\scripts\sportapp-release.ps1 release
```

Para publicar solo uno de los dos o cambiar el incremento:

```powershell
.\scripts\sportapp-release.ps1 release -Repos backend -Bump patch
```

| Fase | Qué pasa |
| --- | --- |
| Plan | muestra, por repositorio, la versión actual, la propuesta y los commits de `develop`; omite los que no tienen cambios; pide confirmar |
| 1. Pull requests | crea `release: <componente> vX.Y.Z` de `develop` a `main`, o reutiliza el PR abierto |
| 2. Pruebas | espera los checks de CI de los dos PR a la vez; un repositorio con pruebas fallidas se detiene y el otro continúa |
| 3. Aprobación | por cada PR muestra el resumen y pregunta si lo apruebas (sección 5); fusiona con un commit de merge |
| 4. Releases | crea la GitHub Release y su tag sobre el commit de merge, con notas generadas y la versión del sistema |
| 5. Validación | espera `release-validation` (backend) o `release-web` (frontend) |
| 6. Cloud Build | espera `release-backend` o `release-frontend` del tag; si terminan en `FAILURE`, muestra el paso que falló, sus líneas de error y el enlace al log. Si el build no arranca en 10 minutos (triggers deshabilitados), da el comando para lanzarlo |
| 7. Plataforma | por cada versión validada **y con imágenes publicadas**, mueve el submódulo de la plataforma al tag y actualiza `release-manifest.yaml` (sección 7) |

Al final imprime un resumen con el resultado de Cloud Build de cada versión.

- El comando `sportapp-gcp.ps1 promote` solo incluye las versiones con imágenes.
- En la primera release, antes va `sportapp-gcp.ps1 setup`, que crea Cloud Run.
- Una versión cuyo build falló no se puede desplegar: corrige en `develop` y publica una nueva con `-Bump patch`. Volver a lanzar el build del mismo tag no sirve, porque Cloud Build lee el `cloudbuild.release.yaml` del commit del tag.

Para consultar o esperar el build de tags ya publicados sin repetir la release:

```powershell
.\scripts\sportapp-release.ps1 builds                                     # último tag de cada repositorio
.\scripts\sportapp-release.ps1 builds -Repos backend -BackendVersion v0.1.1
```

Si algo falla, corrige y vuelve a ejecutar `release`:
- los PR abiertos se reutilizan;
- los repositorios ya publicados no tienen cambios nuevos en `develop` y se omiten.

## 5. Aprobación de los PR

GitHub no permite que el autor de un PR lo apruebe. La pregunta de la fase 3 es la aprobación humana del operador, y siempre se hace, incluso con `-AutoApprove`. Responder algo distinto de `si` omite ese repositorio.

Después de tu aprobación, el script fusiona de una de dos formas:

| Situación | Cómo fusiona |
| --- | --- |
| Hay una cuenta revisora: `$releaseReviewer` con sesión en `gh` en esta estación (`gh auth login` con la cuenta del compañero), o un token en `SPORTAPP_REVIEWER_TOKEN` | la cuenta revisora aprueba el PR y se fusiona de forma normal; la regla de una aprobación de `main` se cumple |
| No hay cuenta revisora | deja un comentario con tu aprobación y fusiona con `--admin`; GitHub registra que se omitió la regla de revisión |

El token de la cuenta revisora nunca se imprime ni se guarda.

## 6. Versiones

- **Propuesta:** el script toma el último tag estable `vX.Y.Z` de cada repositorio y propone el siguiente según `-Bump`. Por defecto es `minor`, porque un sprint con HU incrementa MINOR ([manual de versiones](../docs/manual-versionado.md#regla-de-incremento-por-componente)).
- **Sin tags:** propone `v0.1.0`; la serie `0.x` se usa hasta el MVP.
- **Versión explícita:** para fijarla, usa `-BackendVersion` o `-FrontendVersion`.
- **Versión del sistema:** es la de plataforma, `platformVersion` de [`release-manifest.yaml`](../release-manifest.yaml). Se puede reemplazar con `-SystemVersion`. Aparece en las notas de cada release.

Cada componente conserva su versión individual. En la primera release, `$initialBackendVersion` y `$initialFrontendVersion` de `.env.ps1` deben coincidir con las versiones publicadas: `sportapp-gcp.ps1 setup` las usa para crear Cloud Run.

## 7. Submódulos y manifiesto de la plataforma

El [cierre de sprint](../docs/manual-versionado.md#cierre-del-sprint) pide que la plataforma apunte a los tags publicados. Esto importa en producción: `sportapp-gcp.ps1` toma los Services de GKE de `components/backend`, así que el submódulo debe estar en el tag que se despliega.

En la fase 7, por cada versión validada y con imágenes publicadas, el script hace lo siguiente:

1. Descarga el submódulo si falta. `.gitmodules` declara `update = none`, por eso usa `--checkout`; también activa las rutas largas de Windows.
2. Lo mueve al tag publicado. Si el submódulo tiene cambios locales, no lo mueve, para no perderlos, y te avisa.
3. Actualiza `version`, `ref` y `commit` del componente en `release-manifest.yaml`.
4. Muestra `git status` de esos archivos y los comandos para confirmarlos en una rama. **El script no hace commit:** lo haces tú.
5. Si se publicó el backend, recuerda ejecutar `sportapp-gcp.ps1 up` para reconciliar los Services de GKE.

El manifiesto sigue en `status: draft`. Faltan los datos que solo existen después de Cloud Build y del promotor:

- los digests;
- `contractVersion` y `expectedBffContract`;
- la evidencia.

Se completan antes de publicar la versión de plataforma.

Para hacerlo por separado, por ejemplo si usaste `-SkipPlatform` o publicaste una release a mano, usa el comando `submodules`:

```powershell
.\scripts\sportapp-release.ps1 submodules
.\scripts\sportapp-release.ps1 submodules -Repos backend -BackendVersion v0.1.0
```

## 8. Comandos y opciones

| Comando | Qué hace |
| --- | --- |
| `check` | valida `gh`, permisos y ramas de backend y frontend |
| `status` | cambios pendientes de `develop`, PR abierto y última release de cada repositorio |
| `prepare` | crea `main` en el frontend (sección 3) |
| `release` | flujo completo (sección 4) |
| `builds` | consulta o espera el Cloud Build de los tags publicados y muestra el error si falló (sección 4) |
| `submodules` | mueve los submódulos de la plataforma a los tags y actualiza `release-manifest.yaml` (sección 7) |

| Opción | Efecto |
| --- | --- |
| `-Repos backend,frontend` | repositorios a publicar (por defecto los dos) |
| `-Bump patch\|minor\|major` | incremento propuesto (por defecto `minor`) |
| `-BackendVersion`, `-FrontendVersion` | versión explícita `vX.Y.Z` |
| `-SystemVersion vX.Y.Z` | versión del sistema en lugar de la de `release-manifest.yaml` |
| `-SkipCloudBuild` | no espera Cloud Build (fase 6); se puede consultar después con `builds` |
| `-SkipPlatform` | no mueve los submódulos ni el manifiesto; se puede hacer después con `submodules` |
| `-AutoApprove` | omite las confirmaciones de rutina; nunca la aprobación de los PR |
| `-ConfigFile <ruta.ps1>` | otro archivo de configuración |

## 9. Problemas frecuentes

| Síntoma | Acción |
| --- | --- |
| `no existe main: ejecuta prepare` | ejecuta `prepare` (sección 3) |
| `pruebas fallidas: ...` | corrige en una rama hacia `develop`; el PR de release se actualiza solo y basta con repetir `release` |
| `el PR tiene conflictos con main` | integra `main` en `develop` y repite |
| `el tag vX.Y.Z ya existe` | indica otra versión con `-BackendVersion` o `-FrontendVersion` |
| `no apareció release-*.yml` | revisa *Actions* del repositorio |
| `release-backend` o `release-frontend` terminó en `FAILURE` | el script muestra el paso y el error; corrige el `cloudbuild.release.yaml` (o el código) en `develop` y publica una versión nueva con `-Bump patch` |
| Cloud Build no arrancó con el tag | los triggers estaban deshabilitados al crear el tag: `gcloud builds triggers run release-backend --region=us-central1 --project=<gestión> --tag=vX.Y.Z` (igual con `release-frontend`) |
| `gh pr merge` rechaza el merge | tu cuenta no es administradora: configura una cuenta revisora (sección 5) |
