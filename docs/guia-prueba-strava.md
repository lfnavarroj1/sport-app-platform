# Guía de prueba real con Strava (HU031, EXP-002)

Esta guía prepara la plataforma para la primera corrida real de la integración con Strava (ADR-042) en el ambiente local (Docker Desktop). Cubre solo `platform`: la aplicación OAuth en el portal de Strava, la carga de secretos y la ejecución en el dispositivo la hace el responsable; el cliente móvil lo prueba un ejecutor móvil posterior.

> **Dispositivo de prueba.** Las pruebas móviles de Strava se ejecutan únicamente en el dispositivo Android físico del proyecto: tableta Samsung SM-T970, serie `R52NB04LMCB`, conectada por `adb`. No se usan otros dispositivos virtuales.

## 1. Qué despliega la plataforma

| Elemento | Valor |
| --- | --- |
| Base y usuario PostgreSQL | `terceros` (una sola base; contraseña `TERCEROS_DB_PASSWORD` en el Secret `sportapp-database`) |
| Secret de la aplicación de Strava | `sportapp-third-party` con `STRAVA_CLIENT_ID`, `STRAVA_CLIENT_SECRET` y `STRAVA_TOKEN_KEY` (lo carga el responsable; el repositorio no contiene valores) |
| ConfigMap `sportapp-runtime` | `STRAVA_REDIRECT_URI` y `STRAVA_CONSENT_VERSION` |
| Mensajería (emulador de Pub/Sub, solo local) | tópico `sportapp.terceros.v1`, suscripción `entrenamientos-actividades-externas-v1`, DLQ `sportapp.terceros.actividades.dlq` y su suscripción `…dlq.ops` |
| Cargas (componente `strava-integration` del backend) | Job `third-party-management-migrate-main`, `third-party-management-outbox-publisher`, `third-party-management-sync-worker` y `training-management-external-activity-consumer`, además de `third-party-management` |

En producción los mismos recursos los declara Terraform (módulo `platform`) sobre Cloud SQL, Secret Manager y Pub/Sub administrado, y los despliega Cloud Deploy; esta guía no aplica nada en GCP (sección 8).

## 2. Prerrequisitos

1. Ambiente local aplicado según [preparacion-terraform-local.md](preparacion-terraform-local.md), con el backend en `develop` (incluye `deploy/k8s/components/strava-integration`) e imágenes `sportapp/*` construidas.
2. PostgreSQL con la base `terceros`. El script de inicio solo corre con el volumen vacío: si el ambiente ya existía, destrúyalo y vuelva a aplicarlo (`terraform destroy` y `apply`), como indica la nota de `password_revision`, porque la clave `TERCEROS_DB_PASSWORD` es nueva en `sportapp-database`.
3. Cuenta de Strava del deportista de prueba (el modo inicial de la aplicación admite un solo atleta; ver el paso pendiente 1 de la sección 9).
4. `adb` con la tableta autorizada: `adb devices` debe listar `R52NB04LMCB` en estado `device`.

## 3. Callback de Strava

El callback exacto que Strava debe conocer es la ruta pública de `bff-mobile`:

```text
GET <URL pública de bff-mobile>/v1/integrations/strava/callback?code=…&state=…&scope=…
```

`STRAVA_REDIRECT_URI` debe ser idéntico a la URI que usa el backend al pedir la autorización. Valores de cada ambiente:

| Ambiente | `STRAVA_REDIRECT_URI` | Dominio de callback en el portal de Strava |
| --- | --- | --- |
| Local con la tableta por `adb reverse` (predeterminado) | `http://localhost:18081/v1/integrations/strava/callback` | `localhost` |
| Local con una URL HTTPS pública (túnel) | la URL pública + `/v1/integrations/strava/callback`, pasada con `-var strava_redirect_uri=…` | el dominio de esa URL |
| Producción (Cloud Run) | `https://bff-mobile-<número-del-proyecto>.<región>.run.app/v1/integrations/strava/callback`; la calcula Terraform (`output runtime_config.strava_redirect_uri` de `environments/production`) | `bff-mobile-<número-del-proyecto>.<región>.run.app` |

### Cómo llega la tableta a la plataforma local

Docker Desktop publica `bff-mobile` en el puerto `18081` del equipo (`bff-mobile-local`). La tableta es otro equipo, así que necesita uno de estos caminos:

- **USB con `adb reverse` (predeterminado).** Con la tableta conectada, ejecute:

  ```powershell
  adb -s R52NB04LMCB reverse tcp:18081 tcp:18081
  adb -s R52NB04LMCB reverse --list
  ```

  Desde ese momento `http://localhost:18081` en la tableta (la app y el navegador de Custom Tabs) llega a `bff-mobile` del equipo, y el redireccionamiento de Strava a `http://localhost:18081/v1/integrations/strava/callback` también. La regla se pierde al desconectar la tableta o reiniciar `adb`; vuelva a crearla.
- **Red local.** Tableta y equipo en la misma red; el equipo se alcanza como `http://<IP-del-equipo>:18081` (puede requerir una regla del Firewall de Windows para ese puerto). En este camino `localhost` no sirve para el callback: hace falta una URI con esa IP o nombre, registrada igual en Strava y en `strava_redirect_uri`.
- **Dirección de API que usa la aplicación.** Qué URL base de `bff-mobile` configura el cliente móvil (`http://localhost:18081` con `adb reverse`, o la IP local) es decisión del ejecutor móvil; la plataforma solo garantiza que el puerto `18081` responde en el equipo.

> **Pendiente del responsable.** Strava debe aceptar `localhost` como dominio de callback en su flujo móvil (`https://www.strava.com/oauth/mobile/authorize`) para esta aplicación. La plataforma no puede comprobarlo sin registrar la aplicación. Si Strava lo rechaza, use un túnel HTTPS público (o la URL de producción) y pase `strava_redirect_uri`; la elección del túnel también es del responsable.

## 4. Registrar la aplicación en Strava (responsable)

Se hace una vez por ambiente, en `https://www.strava.com/settings/api`:

1. Crear la aplicación (nombre, categoría, sitio web) y subir su icono.
2. **Authorization Callback Domain**: el dominio de la tercera columna de la tabla anterior (sin esquema ni ruta).
3. Guardar y copiar el *Client ID* y el *Client Secret*. No los comparta ni los confirme en Git.
4. Scopes que solicita SportApp: `read,activity:read` (los fija el backend; no se configuran en el portal).

## 5. Cargar los secretos (responsable)

El Secret debe existir antes de activar el componente. Los valores se escriben en la terminal y no quedan en archivos ni en el historial del repositorio.

```powershell
$id  = Read-Host "STRAVA_CLIENT_ID"
$sec = Read-Host "STRAVA_CLIENT_SECRET" -AsSecureString
$secPlain = [System.Net.NetworkCredential]::new("", $sec).Password
# Clave AES-256-GCM de los tokens: 32 bytes en base64 URL-safe.
$bytes = New-Object byte[] 32
[System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
$key = [Convert]::ToBase64String($bytes).Replace("+", "-").Replace("/", "_")

kubectl --context docker-desktop --namespace sportapp-local create secret generic sportapp-third-party `
  --from-literal=STRAVA_CLIENT_ID=$id `
  --from-literal=STRAVA_CLIENT_SECRET=$secPlain `
  --from-literal=STRAVA_TOKEN_KEY=$key
Remove-Variable id, sec, secPlain, bytes, key
```

El namespace debe existir (lo crea el primer `terraform apply`). Conserve la clave `STRAVA_TOKEN_KEY`: si se pierde o se cambia, los tokens cifrados ya guardados dejan de poder descifrarse y cada deportista debe vincular de nuevo. Para reemplazar el Secret, elimínelo (`kubectl delete secret sportapp-third-party`) y créelo otra vez.

## 6. Orden de arranque

1. `terraform apply` del ambiente local (como siempre) con la base `terceros`, el emulador de Pub/Sub con sus tópicos y la configuración del callback. Si hace falta otro callback o versión de consentimiento: `-var strava_redirect_uri=…` y `-var strava_consent_version=…`.
2. Cargar el Secret `sportapp-third-party` (sección 5).
3. Activar la integración:

   ```powershell
   terraform apply -var strava_integration_enabled=true
   ```

   Terraform aplica el Job de migración `third-party-management-migrate-main`, espera a que termine y despliega `third-party-management`, `terceros-outbox-publisher`, `terceros-sync-worker` y el consumidor de Entrenamientos esperando su rollout. `terraform output strava` muestra el callback y los nombres de mensajería, sin secretos.
4. Con la tableta conectada: `adb -s R52NB04LMCB reverse tcp:18081 tcp:18081`.

`STRAVA_CONSENT_VERSION` vale `local-dev` en local; la versión de producción debe aprobarla el responsable (sección 9).

## 7. Verificación

Todos los comandos usan `--context docker-desktop --namespace sportapp-local`.

1. **Cargas listas.**

   ```powershell
   kubectl --context docker-desktop --namespace sportapp-local get pods
   kubectl --context docker-desktop --namespace sportapp-local get job third-party-management-migrate-main
   ```

   Deben estar `Running` `third-party-management`, `third-party-management-outbox-publisher`, `third-party-management-sync-worker` y `training-management-external-activity-consumer`, y el Job en `Complete`. Si `third-party-management` no queda listo, falta el Secret o `STRAVA_REDIRECT_URI`/`STRAVA_CONSENT_VERSION` (su `/health/ready` informa `strava_configuration`).
2. **Vinculación.** Un ejecutor móvil, desde la tableta, ejecuta «Integrar con Strava», autoriza en Strava y regresa por `sportapp://integrations/strava?result=LINKED`. En el equipo:

   ```powershell
   kubectl --context docker-desktop --namespace sportapp-local exec statefulset/postgres -- psql -U postgres -d terceros -c "select count(*) from external_account"
   ```

   El conteo sube a 1. Los tokens se guardan cifrados; no deben aparecer en ningún registro (`kubectl logs deployment/third-party-management`).
3. **Sincronización.** «Sincronizar ahora» responde `202` con `sync_run_id`. Compruebe `select count(*) from sync_run` y `select count(*) from imported_activity` en la base `terceros` y los registros de `third-party-management-sync-worker`.
4. **Evento `actividad.importada.v1`.** El publicador escribe en `sportapp.terceros.v1`; la suscripción `entrenamientos-actividades-externas-v1` la consume el consumidor de Entrenamientos. Para ver los mensajes sin interferir con el consumidor, cree antes de sincronizar una suscripción propia en el emulador de Pub/Sub (publicado en `localhost:18085`):

   ```powershell
   $b = "http://localhost:18085/v1/projects/sportapp-local"
   Invoke-RestMethod -Method Put -Uri "$b/subscriptions/verificacion-hu031" -ContentType "application/json" `
     -Body '{"topic":"projects/sportapp-local/topics/sportapp.terceros.v1"}'
   # después de sincronizar:
   Invoke-RestMethod -Method Post -Uri "$b/subscriptions/verificacion-hu031:pull" -ContentType "application/json" -Body '{"maxMessages":5}'
   ```

   Cada mensaje trae `event_type = actividad.importada.v1` en sus atributos; el cuerpo va en base64 y no debe contener tokens. Un mensaje que el consumidor no logre procesar termina tras 10 entregas en `sportapp.terceros.actividades.dlq` (suscripción `sportapp.terceros.actividades.dlq.ops`).
5. **Entrenamientos.** La actividad aparece en el historial con `source = STRAVA` (`GET /v1/training-history` por `bff-mobile`) y en `training_session_history` de `entrenamientos_read`.
6. **Desvinculación.** «Desvincular» borra los tokens (`external_account` sin credenciales) y conserva las actividades importadas.

## 8. Producción (solo declarada, sin aplicar)

Terraform declara, sin aplicarse todavía, la base `terceros` y su contraseña (`db-password-terceros`), los secretos `strava-client-id`, `strava-client-secret` y `strava-token-key` en Secret Manager (contenedores vacíos), el tópico, la suscripción y la DLQ en Pub/Sub administrado, las identidades de las cargas de Terceros y del consumidor, el balanceador interno de `third-party-management` para `bff-mobile` (`THIRD_PARTY_MANAGEMENT_BASE_URL`) y `STRAVA_REDIRECT_URI` en `sportapp-runtime`. Cloud Deploy incluye el componente `strava-integration` y su Job de migración. Cuando el responsable ordene aplicar:

1. cargar cada secreto con `gcloud secrets versions add <secreto> --data-file=-`;
2. definir `strava_consent_version` aprobado;
3. activar `sync_strava_secret = true` en `environments/production-workloads` para copiar el Secret `sportapp-third-party` a GKE.

## 9. Pendientes del responsable

1. Registrar la aplicación en Strava por ambiente y su dominio de callback (sección 4). El modo inicial admite un solo atleta; antes de abrirla a más deportistas hay que ampliar la capacidad y solicitar revisión al superar diez atletas conectados.
2. Confirmar que Strava acepta `localhost` en el flujo móvil o elegir un túnel/URL pública HTTPS para el callback (sección 3).
3. Cargar los secretos (sección 5 en local; sección 8 en producción).
4. Aprobar la versión del texto de consentimiento (`STRAVA_CONSENT_VERSION`) de producción. Local usa `local-dev`.
5. Decidir la capa de borde de producción: si la URL pública de `bff-mobile` deja de ser la de Cloud Run, el callback registrado en Strava y `STRAVA_REDIRECT_URI` deben cambiar juntos.
