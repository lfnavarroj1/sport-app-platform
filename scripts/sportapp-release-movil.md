# Uso de `sportapp-release-movil.ps1`

[`sportapp-release-movil.ps1`](sportapp-release-movil.ps1) publica la release de la **aplicación móvil** desde la estación del operador. Va aparte de [`sportapp-release.ps1`](sportapp-release.md) porque el móvil no influye en los despliegues: no tiene imagen ni pasa por Cloud Build o Cloud Deploy. Se puede publicar en cualquier momento, sin tocar backend, frontend ni GCP.

Ejecuta, en orden:

1. crea o reutiliza el pull request `develop` → `main`;
2. espera a que terminen sus pruebas;
3. pide la aprobación en la terminal y fusiona;
4. crea la GitHub Release `vX.Y.Z` sobre el commit de merge;
5. espera el workflow `release-mobile`;
6. compila, firma y adjunta a la release el APK de producción;
7. mueve el submódulo `components/mobile` de la plataforma al tag y actualiza `release-manifest.yaml`.

El APK apunta al `bff-mobile` de producción. Funciona solo mientras el plano operativo esté encendido (`sportapp-gcp.ps1 up`), pero publicarlo no depende de que lo esté.

## Contenido

1. [Requisitos](#1-requisitos)
2. [Configuración](#2-configuración)
3. [Preparación única](#3-preparación-única)
4. [Publicar una release](#4-publicar-una-release)
5. [APK de producción](#5-apk-de-producción)
6. [Versiones](#6-versiones)
7. [Comandos y opciones](#7-comandos-y-opciones)
8. [Problemas frecuentes](#8-problemas-frecuentes)

## 1. Requisitos

| Herramienta | Para qué | Instalación |
| --- | --- | --- |
| GitHub CLI (`gh`) con sesión iniciada | PR, merge y release | `winget install --id GitHub.cli -e` y `gh auth login` |
| Git | clon local del móvil y submódulo de la plataforma | `winget install --id Git.Git -e` |
| Java 17 o superior | iniciar Gradle; Gradle descarga solo el JDK 25 del proyecto | ya instalado si `java -version` responde |
| Android SDK con build-tools | compilar y verificar el APK (`apksigner`, `aapt2`) | Android Studio o `ANDROID_HOME` |
| Google Cloud CLI | leer el número del proyecto de producción para la URL de `bff-mobile` | solo si no defines `$mobileBffBaseUrl` |

Para comprobarlo:

```powershell
.\scripts\sportapp-release-movil.ps1 check
```

## 2. Configuración

El script lee `platform\.env.ps1`; la plantilla es [`.env.example.ps1`](../.env.example.ps1).

| Variable | Valor por defecto | Uso |
| --- | --- | --- |
| `$githubOwner` | `lfnavarroj1` | dueño del repositorio |
| `$releaseReviewer` | — | cuenta de un compañero que aprueba el PR ([aprobación](sportapp-release.md#5-aprobación-de-los-pr)) |
| `$mobileKeystoreFile` | `%USERPROFILE%\.sportapp\sportapp-release.jks` | almacén de claves de firma, fuera del repositorio |
| `$mobileKeyAlias` | `sportapp` | alias de la clave de firma |
| `$mobileRepoPath` | `..\movil` | clon local del móvil |
| `$mobileBffBaseUrl` | `https://bff-mobile-<número de $production>.<$region>.run.app/` | URL de producción que usa el APK |
| `$production`, `$region` | los de `sportapp-gcp.ps1` | calcular la URL anterior |

Nunca guardes contraseñas en `.env.ps1`: las de firma se piden al compilar. Si prefieres no escribirlas cada vez, defínelas solo en la sesión con `SPORTAPP_SIGNING_STORE_PASSWORD` y `SPORTAPP_SIGNING_KEY_PASSWORD`; el script las borra al terminar.

## 3. Preparación única

1. **Rama `main`.** `release-mobile` exige que el tag esté en `main`, y el móvil usa `master`:

   ```powershell
   .\scripts\sportapp-release-movil.ps1 prepare
   ```

   Renombra `master` a `main`; GitHub conserva los PR, redirige la rama y actualiza la rama por defecto. Después protege `main` (*Settings → Rules*).

2. **Almacén de claves:**

   ```powershell
   .\scripts\sportapp-release-movil.ps1 keystore
   ```

   `keytool` pide una contraseña y los datos del certificado. **Guarda una copia del archivo y de la contraseña en un lugar seguro:** sin ellos no podrás publicar actualizaciones de la app instalada.

3. **Versión y firma configurables.** Fusiona en `develop` del móvil la rama `chore/apk-produccion-versionado`, que hace que `app/build.gradle.kts` reciba la versión, la versión del sistema y la firma. Sin ella el script se detiene antes de compilar.

## 4. Publicar una release

```powershell
.\scripts\sportapp-release-movil.ps1 status
.\scripts\sportapp-release-movil.ps1 release
```

Las fases de PR, pruebas, aprobación, release y validación son las mismas de [`sportapp-release.ps1`](sportapp-release.md#4-publicar-una-release), solo para el móvil. La aprobación del PR siempre se pregunta en la terminal.

Después:

1. **APK:** si `release-mobile` terminó bien, compila y adjunta el APK (sección 5).
2. **Plataforma:** mueve `components/mobile` al tag y actualiza en `release-manifest.yaml` su `version`, `ref`, `commit`, `versionCode` y el `sha256` del APK. No hace commit: muestra los comandos para que lo confirmes en una rama.

Si algo falla, corrige y vuelve a ejecutar `release`: el PR abierto se reutiliza.

## 5. APK de producción

`release-mobile` valida la release en GitHub Actions y produce un APK sin firmar, que Android no instala. El APK que se publica lo compila el script en tu estación. Así la clave de firma nunca sale de tu equipo.

1. Crea un `git worktree` temporal en el commit exacto del tag.
2. Ejecuta `:app:assembleRelease` con:
   - `versionName` = versión del tag;
   - `versionCode` = `MAJOR*1000000 + MINOR*1000 + PATCH` (`v0.2.0` → `2000`);
   - `BuildConfig.SYSTEM_VERSION` = versión del sistema;
   - la URL de `bff-mobile` en Cloud Run.
3. Firma con `$mobileKeystoreFile`. `apksigner` verifica la firma y `aapt2` la versión.
4. Adjunta a la release:
   - `sportapp-movil-vX.Y.Z-sistema-vA.B.C.apk`;
   - `SHA256SUMS`;
   - `artifact.txt`, con versión, `versionCode`, sistema, commit, URL y huella del certificado.

Para repetir o rehacer solo el APK de una release existente:

```powershell
.\scripts\sportapp-release-movil.ps1 apk -MobileVersion v0.2.0
```

## 6. Versiones

- **Propuesta:** el script toma el último tag estable del móvil y propone el siguiente según `-Bump` (por defecto `minor`). Sin tags propone `v0.1.0`. Para fijarla usa `-MobileVersion`.
- **Versión del sistema:** es `platformVersion` de [`release-manifest.yaml`](../release-manifest.yaml), o la que indiques con `-SystemVersion`. Va en el nombre del APK, en `BuildConfig.SYSTEM_VERSION` y en las notas de la release.

## 7. Comandos y opciones

| Comando | Qué hace |
| --- | --- |
| `check` | valida `gh`, ramas, Java, Android SDK, almacén de claves y URL de producción |
| `status` | cambios pendientes de `develop`, PR abierto y última release |
| `prepare` | renombra `master` a `main` (sección 3) |
| `keystore` | crea el almacén de claves (sección 3) |
| `release` | flujo completo (sección 4) |
| `apk` | compila, firma y adjunta el APK de una release existente |
| `submodules` | mueve `components/mobile` al tag (por defecto, el último) y actualiza `release-manifest.yaml` |

| Opción | Efecto |
| --- | --- |
| `-Bump patch\|minor\|major` | incremento propuesto (por defecto `minor`) |
| `-MobileVersion vX.Y.Z` | versión explícita |
| `-SystemVersion vX.Y.Z` | versión del sistema en lugar de la de `release-manifest.yaml` |
| `-SkipApk` | no compila el APK; se puede hacer después con `apk` |
| `-SkipPlatform` | no mueve el submódulo ni el manifiesto; se puede hacer después con `submodules` |
| `-AutoApprove` | omite las confirmaciones de rutina; nunca la aprobación del PR |
| `-ConfigFile <ruta.ps1>` | otro archivo de configuración |

## 8. Problemas frecuentes

| Síntoma | Acción |
| --- | --- |
| `no existe main: ejecuta prepare` | `prepare` (sección 3) |
| `el PR tiene conflictos con main` | integra `main` en `develop` (los PR #5 y #7 se fusionaron en `master`) y repite |
| `pruebas fallidas: ...` | corrige en una rama hacia `develop` y repite `release` |
| `no apareció release-mobile.yml` | revisa *Actions*; si la validación pasó, adjunta el APK con `apk` |
| `release-mobile no terminó correctamente` | no se publica APK; corrige y publica una versión nueva |
| `El tag ... no incluye la versión y la firma configurables` | fusiona `chore/apk-produccion-versionado` en `develop` y publica una versión nueva |
| `No existe el almacén de claves` | `keystore` |
| `Gradle no produjo un APK firmado` | revisa las contraseñas y el alias; la salida de Gradle muestra el error |
| `Se requiere Java 17 o superior` | instala un JDK 17+; `gradlew.bat` exige Java 21, por eso el script usa directamente el JAR del wrapper |
