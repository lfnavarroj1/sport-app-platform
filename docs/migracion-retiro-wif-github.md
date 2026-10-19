# Migración: retiro del acceso de GitHub a GCP

Esta guía aplica solo si el bootstrap o la producción ya se aplicaron con el diseño anterior: Workload Identity Federation (WIF) para GitHub, cuentas `ci-delivery-*` y workloads de GKE o imágenes de Cloud Run administrados por Terraform. Con un ambiente nuevo no hay nada que migrar: aplica el código vigente siguiendo la [preparación de GCP](preparacion-terraform-gcp.md).

Todo se hace desde la estación del operador, con un plan guardado y revisado por otra persona. Ningún paso usa `terraform state rm`, `terraform import` automático ni cambios manuales en la consola, salvo los indicados.

## 1. Qué cambia en cada raíz

| Raíz | Recursos que el plan destruye | Recursos que el plan olvida sin tocar GCP | Recursos nuevos |
| --- | --- | --- | --- |
| `bootstrap/gcp-state` | `google_iam_workload_identity_pool.github`, `google_iam_workload_identity_pool_provider.github`, `google_service_account.delivery["production"]` (`ci-delivery-production`) | `google_service_account_iam_member.plan_github`, `apply_github`, `delivery_github`, `operators_plan` y `operators_apply` (bloques `removed` de `migration.tf`) | políticas IAM autoritativas de `tf-plan`/`tf-apply`; `cloud-build-backend`, `cloud-build-frontend`, `release-promoter`, `cloud-deploy-execution` y sus permisos |
| `environments/production` | el repositorio `sportapp` de Artifact Registry (si existía) y el binding `artifact_registry_writers` de `ci-delivery` | — | `sportapp-backend`, `sportapp-frontend`, permisos cruzados de `cloud-deploy-execution` |
| `environments/production-workloads` | el ConfigMap `sportapp-runtime-<hash>` | Deployments, Jobs de migración y `terraform_data.migration_revision` (bloques `removed`) | `sportapp-runtime` con nombre fijo, RBAC de Cloud Deploy |
| `environments/delivery` | — | — | toda la raíz |

Las políticas autoritativas reemplazan la política IAM completa de `tf-plan-production` y `tf-apply-production` por una sola regla: `roles/iam.serviceAccountTokenCreator` para `operators`. Por eso los bindings de GitHub desaparecen sin destruirse uno por uno y sin una ventana en la que los operadores pierdan acceso.

## 2. Revocar primero lo que existe en GitHub

Antes de cualquier `apply`, en cada repositorio (`sport-app-platform`, `sport-app-backend`, `sport-app-frontend`):

1. Elimina las variables y secretos de GitHub `GCP_WORKLOAD_IDENTITY_PROVIDER`, `PROD_TF_PLAN_SA`, `PROD_TF_APPLY_SA` y `GCP_DELIVERY_SERVICE_ACCOUNT` (Settings → Secrets and variables → Actions, también en los Environments).
2. Elimina o desactiva los workflows que usaban `google-github-actions/auth` o `permissions: id-token: write`. En la plataforma solo queda `validate-platform.yml`.
3. Comprueba que no queda ninguna referencia:

   ```powershell
   rg -n "google-github-actions/auth|id-token: write|GCP_WORKLOAD_IDENTITY_PROVIDER|PROD_TF_(PLAN|APPLY)_SA|GCP_DELIVERY_SERVICE_ACCOUNT" .github
   ```

Así, aunque el WIF siguiera existiendo unos minutos, ningún workflow intentaría usarlo.

## 3. Plan del bootstrap

```powershell
cd infra\terraform\bootstrap\gcp-state
terraform init
terraform plan -out=tfplan
terraform show tfplan
```

Revisa que el plan:

- destruye exactamente el pool `github`, su provider `sport-app-platform` y `ci-delivery-production`;
- muestra como «removed from state» (no destruidos) los cinco `google_service_account_iam_member` anteriores;
- crea `google_service_account_iam_policy.plan["production"]` y `.apply["production"]` con un único binding de `roles/iam.serviceAccountTokenCreator` para los `operators`;
- crea las cuatro identidades de entrega sin roles `owner`, `editor`, administrativos ni `clouddeploy.approver`;
- no crea llaves de cuentas de servicio.

Si aparece cualquier otra destrucción (bucket de estado, `tf-apply-*`, presupuesto), **no apliques**: corrige el código o las variables y genera un plan nuevo.

## 4. Aplicar desde la estación del operador

```powershell
terraform apply tfplan
```

El pool de WIF queda eliminado de forma lógica durante 30 días (GCP lo puede restaurar en ese plazo, pero no emite tokens). No lo restaures.

## 5. Verificar que GitHub ya no obtiene tokens

```powershell
$mgmt = "sportapp-mgmt-1234"
gcloud iam workload-identity-pools list --location=global --project=$mgmt --show-deleted
gcloud iam service-accounts get-iam-policy "tf-apply-production@$mgmt.iam.gserviceaccount.com"
gcloud iam service-accounts get-iam-policy "tf-plan-production@$mgmt.iam.gserviceaccount.com"
gcloud iam service-accounts list --project=$mgmt --filter="email~^ci-delivery"
```

Resultado esperado:

- el pool `github` solo aparece como `DELETED`;
- las dos políticas contienen únicamente `roles/iam.serviceAccountTokenCreator` para personas o grupos;
- no existe ninguna cuenta `ci-delivery-*`.

Cualquier workflow antiguo que todavía intente autenticarse falla en el intercambio del token OIDC. Esa falla es la confirmación esperada.

## 6. Producción y cargas

1. `environments/production`: genera el plan con las nuevas variables (`delivery_identities`; elimina `artifact_registry_writers` de `gcp.auto.tfvars`). Si el repositorio `sportapp` ya tiene imágenes en uso, primero vuelve a publicar la release con Cloud Build en `sportapp-backend`/`sportapp-frontend` y crea las revisiones nuevas; recién después aplica el plan que borra `sportapp`.
2. `environments/production-workloads`: el plan debe mostrar los Deployments, los Jobs y `terraform_data.migration_revision` como «removed from state» (siguen corriendo) y mover los Services de `kustomization_resource.config` a `kustomization_resource.services`. El ConfigMap con sufijo de hash solo puede borrarse cuando el primer rollout de Cloud Deploy haya reemplazado los pods (sus manifiestos usan `sportapp-runtime` sin sufijo): aplica esta raíz después de ese rollout o acepta que los pods existentes conserven su configuración hasta entonces.
3. `environments/delivery`: aplica según la [primera release](preparacion-terraform-gcp.md#13-primera-release-y-cierre-de-la-preparación-fija).
4. Ejecuta de nuevo `terraform plan` en las tres raíces: no debe proponer cambios sobre imágenes, revisiones, Deployments ni Jobs.

## 7. Si algo sale mal

- **Un operador pierde acceso a `tf-apply-production`:** la política autoritativa solo contiene `operators`. Corrige `bootstrap.auto.tfvars` y aplica el bootstrap con las credenciales del propietario del proyecto (no con la cuenta impersonada).
- **El plan quiere destruir un Deployment:** falta un bloque `removed`; no apliques y revisa `production-workloads/migration.tf`.
- **Se necesita retirar algo del estado que el código no cubre:** documenta el análisis en el PR y obtén aprobación antes de usar `terraform state rm`. Nunca lo automatices.
