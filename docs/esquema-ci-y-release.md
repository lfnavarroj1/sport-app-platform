# Integración continua y release de SportApp

## Objetivo

SportApp conserva versiones independientes de backend, frontend web y móvil. Una versión de `sport-app-platform` identifica la combinación que fue integrada, probada y aceptada para un sprint.

Cada repositorio construye su artefacto una sola vez. La plataforma registra y promueve sus digests o checksums; nunca recompila un componente para pasarlo de staging a producción.

## Situación actual

Al 9 de octubre de 2026 los repositorios públicos de backend, frontend y móvil conservan `master` y únicamente el README inicial. Backend y frontend tienen código y workflows preparados localmente, pero todavía no están confirmados ni publicados. `sport-app-platform` usa `main`, pero aún no contiene workflows ni manifiesto ejecutable.

Por lo tanto, este es el procedimiento acordado para implementar; todavía no representa un release ejecutable en GitHub Actions.

## Qué hace cada evento

| Evento | Validación | Artefacto | Despliegue |
| --- | --- | --- | --- |
| Push a `feature/**`, `fix/**` o `chore/**` | rápida | no publica | ninguno |
| PR hacia `develop` | completa | candidato no publicado | opcionalmente efímero |
| Merge a `develop` | completa | publica por commit/digest | desarrollo |
| PR `release/**` hacia `main` de un componente | release del componente | publica al aprobar y etiquetar | no libera todo SportApp |
| PR `release/**` en la plataforma | manifiesto, contratos, integración y E2E | reutiliza artefactos publicados | staging |
| Tag de plataforma | congela la composición | manifiesto y notas | habilita producción |
| Promoción manual aprobada | smoke y comprobación | mismos digests | producción |

```mermaid
flowchart LR
    PUSH[Push de una HU] --> CI[CI del componente]
    CI --> PR[PR hacia develop]
    PR --> DEV[Merge y entrega a development]
    DEV --> RC[Release del componente]
    RC --> RP[PR de release en plataforma]
    RP --> ST[Integración, E2E y staging]
    ST --> TAG[Tag de plataforma]
    TAG --> PROD[Promoción aprobada a producción]
```

Un push de una rama de trabajo nunca fusiona ni despliega por sí mismo.

## Desde dónde se lanza cada release

| Release | Repositorio | Resultado |
| --- | --- | --- |
| Backend | `sport-app-backend` | versión backend y ocho imágenes OCI por digest |
| Frontend | `sport-app-frontend` | versión web y artefacto por checksum o digest |
| Móvil | `sport-app-movil` | versión móvil, `versionCode` y APK/AAB por checksum |
| SportApp completo | `sport-app-platform` | manifiesto compatible, pruebas transversales y versión del sprint |

## Cómo lanzar una release completa

Antes de iniciar, backend y frontend deben tener tags y artefactos publicados. Luego se ejecuta en `sport-app-platform` el workflow objetivo `prepare-platform-release.yml` con la versión de plataforma y las referencias de los componentes:

```powershell
gh workflow run prepare-platform-release.yml --repo lfnavarroj1/sport-app-platform --ref main -f platform_version=0.1.0 -f backend_ref=v0.2.0 -f frontend_ref=v0.1.0 -f mobile_ref=v0.1.0
```

Este comando funcionará cuando el workflow sea implementado. Su ejecución debe:

1. comprobar que los tags existen y obtener sus commits;
2. recuperar los descriptores y artefactos publicados;
3. actualizar los submódulos y `release-manifest.yaml`;
4. crear `release/v0.1.0` y un PR, sin desplegar producción;
5. ejecutar contratos, integración, E2E, seguridad y staging;
6. permitir aprobación y creación del tag de plataforma;
7. promover a producción los mismos digests mediante un ambiente protegido.

## Manifiesto de composición

El manifiesto registra números independientes y prueba qué versiones funcionan juntas:

```yaml
platformVersion: 0.1.0
components:
  backend:
    version: 0.2.0
    ref: v0.2.0
    commit: <sha-completo>
    artifacts:
      bff-web: <imagen-por-digest>
      users-management: <imagen-por-digest>
  frontend:
    version: 0.1.0
    ref: v0.1.0
    commit: <sha-completo>
    artifact: <imagen-por-digest-o-checksum>
```

En una release real no se permiten marcadores. Backend y frontend no necesitan compartir el mismo número; deben coincidir en el contrato declarado y en la combinación aprobada por la plataforma.

## Verificación de las versiones desplegadas

- el frontend publica `version.json` con versión, commit y contrato esperado;
- el BFF publica `GET /version` con versión, commit y contrato ofrecido;
- la plataforma inyecta su versión como configuración de despliegue;
- el smoke posterior compara esos datos y los digests desplegados contra el manifiesto;
- cualquier diferencia bloquea la promoción o inicia el procedimiento de rollback.

```text
Plataforma: v0.1.0
Frontend:   v0.1.0 · commit 89abcdef...
Backend:    v0.2.0 · commit 01234567...
Contrato:   v1.0.0 · compatible
```

## Workflows que deben implementarse

| Ubicación | Workflows principales |
| --- | --- |
| Backend | `ci.yml`, `deliver-development.yml`, `release-backend.yml` |
| Frontend | `ci-web.yml`, `deliver-web-development.yml`, `release-web.yml` |
| Móvil | `ci-mobile.yml`, `release-mobile.yml` |
| Plataforma | `validate-platform.yml`, `prepare-platform-release.yml`, `test-platform-release.yml`, `release-platform.yml`, `promote-platform.yml`, `rollback-platform.yml` |

## Condiciones previas de activación

1. normalizar `master` a `main` o ajustar conscientemente los triggers;
2. crear y proteger `develop` y `main`;
3. confirmar y publicar el código y los workflows locales;
4. crear el esquema y validador de `release-manifest.yaml`;
5. configurar GitHub Environments y OIDC/WIF;
6. definir Artifact Registry y destinos de development, staging y production;
7. implementar `version.json`, `GET /version` y el verificador posterior al despliegue.
