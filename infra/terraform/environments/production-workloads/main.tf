# Base Kubernetes de SportApp en el GKE de producción: lo que comparten las
# cargas y no cambia con cada release.
#
# Propiedad (docs/preparacion-terraform-gcp.md, sección 6.4):
# - Terraform: namespace, KSA y Workload Identity, Secrets, ConfigMap
#   sportapp-runtime, Services (incluidos los balanceadores internos que usan
#   los BFF de Cloud Run) y el RBAC de Cloud Deploy.
# - Cloud Deploy (deploy/clouddeploy/gke): Deployments, Jobs de migración,
#   imágenes por digest, réplicas, readiness y rollback. Esta raíz nunca
#   administra apps/* ni batch/*; las pruebas fallan si vuelve a hacerlo.
#
# Estado propio; lee de environments/production el clúster, las identidades, la
# IP de Cloud SQL, las IP internas y la configuración no secreta. Las
# contraseñas y la clave JWT se copian de Secret Manager con valores efímeros.

data "terraform_remote_state" "platform" {
  backend = "gcs"
  config = {
    bucket                      = var.state_bucket
    prefix                      = "sportapp/production"
    impersonate_service_account = var.impersonate_service_account
  }
}

locals {
  platform  = data.terraform_remote_state.platform.outputs
  gke       = local.platform.gke
  namespace = local.platform.gke.namespace
  runtime   = local.platform.runtime_config

  backend_manifests = "${var.backend_path}/deploy/k8s/base"

  # KSA -> cuenta GCP (Workload Identity). Las KSA <servicio>-migrate son de los
  # Jobs de migración; las demás tienen el nombre de su Deployment.
  identities = local.platform.gke_workload_identities

  # Usuario PostgreSQL (dominio) -> clave del Secret sportapp-database.
  database_passwords = { for domain, secret in local.platform.cloud_sql.password_secrets : "${upper(domain)}_DB_PASSWORD" => secret }

  # Cloud Deploy actúa como esta cuenta de Google en el clúster (usuario RBAC).
  deploy_execution = local.platform.delivery_identities.deploy_execution

  # Services que reciben los BFF por balanceador interno y que Cloud Deploy
  # consulta en los smoke tests.
  internal_apis = local.platform.gke_internal_apis
}

resource "kubernetes_namespace_v1" "sportapp" {
  metadata {
    name = local.namespace
    labels = {
      "app.kubernetes.io/part-of"    = "sportapp"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_service_account_v1" "workload" {
  for_each = local.identities

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.sportapp.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = each.value
    }
  }

  # Workload Identity usa el servidor de metadatos de GKE, no el token montado.
  automount_service_account_token = false
}

# Configuración no secreta. Nombre fijo: los manifiestos de Cloud Deploy la
# referencian como sportapp-runtime. Un cambio aquí llega a los pods en el
# siguiente rollout (nueva release), no reinicia cargas por sí solo.
resource "kubernetes_config_map_v1" "runtime" {
  metadata {
    name      = "sportapp-runtime"
    namespace = kubernetes_namespace_v1.sportapp.metadata[0].name
    labels = {
      "app.kubernetes.io/part-of"    = "sportapp"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    APP_ENV   = local.runtime.app_env
    LOG_LEVEL = var.log_level
    # IP privada de Cloud SQL; la instancia exige TLS y libpq lo negocia.
    DATABASE_HOST                        = local.runtime.database_host
    REGISTRATION_POLICIES_VERSION        = local.runtime.registration_policies_version
    HEALTH_DATA_CONSENT_VERSION          = local.runtime.health_data_consent_version
    AFFILIATION_EXPECTED_CATALOG_VERSION = local.runtime.affiliation_expected_catalog_version
    USERS_MANAGEMENT_BASE_URL            = "http://users-management"
    # Pub/Sub administrado: sin PUBSUB_EMULATOR_HOST.
    PUBSUB_PROJECT_ID = local.runtime.project_id
  }
}

# Secrets que exigen los manifiestos del backend, leídos de Secret Manager
# durante el plan y el apply (la identidad necesita secretAccessor).
# prevent_destroy: sync_secrets = false nunca borra los Secrets existentes.
ephemeral "google_secret_manager_secret_version" "database" {
  for_each = var.sync_secrets ? local.database_passwords : {}

  secret = each.value
}

resource "kubernetes_secret_v1" "database" {
  count = var.sync_secrets ? 1 : 0

  metadata {
    name      = "sportapp-database"
    namespace = kubernetes_namespace_v1.sportapp.metadata[0].name
  }

  data_wo          = { for key, version in ephemeral.google_secret_manager_secret_version.database : key => version.secret_data }
  data_wo_revision = var.secrets_revision

  lifecycle {
    prevent_destroy = true
  }
}

ephemeral "google_secret_manager_secret_version" "users_jwt" {
  count = var.sync_secrets ? 1 : 0

  secret = "users-jwt-private-key"
}

resource "kubernetes_secret_v1" "users_jwt" {
  count = var.sync_secrets ? 1 : 0

  metadata {
    name      = "sportapp-users-jwt"
    namespace = kubernetes_namespace_v1.sportapp.metadata[0].name
  }

  data_wo = {
    JWT_PRIVATE_KEY = ephemeral.google_secret_manager_secret_version.users_jwt[0].secret_data
  }
  data_wo_revision = var.secrets_revision

  lifecycle {
    prevent_destroy = true
  }
}

check "secrets_sincronizados" {
  assert {
    condition     = var.sync_secrets
    error_message = "sync_secrets = false: el plan no lee Secret Manager ni gestiona sportapp-database y sportapp-users-jwt. No aplique así un ambiente nuevo: las cargas no arrancarían sin esos Secrets."
  }
}

# --- Services del backend ----------------------------------------------------
#
# Se renderizan los manifiestos del backend y Terraform aplica solamente sus
# Services. Deployments y Jobs del mismo render los aplica Cloud Deploy.

data "kustomization_overlay" "backend" {
  namespace = local.namespace
  resources = [local.backend_manifests]

  # bff-web y bff-mobile corren en Cloud Run.
  dynamic "patches" {
    for_each = toset(["bff-web", "bff-mobile"])
    content {
      patch = <<-EOT
        $patch: delete
        apiVersion: v1
        kind: Service
        metadata:
          name: ${patches.value}
      EOT
    }
  }

  # APIs que llaman los BFF: balanceador interno en la IP reservada por
  # environments/production, alcanzable solo desde la subred de Cloud Run.
  # Dentro del clúster se siguen llamando por su nombre (http://<servicio>).
  dynamic "patches" {
    for_each = local.internal_apis
    content {
      patch = <<-EOT
        apiVersion: v1
        kind: Service
        metadata:
          name: ${patches.key}
          annotations:
            networking.gke.io/load-balancer-type: Internal
        spec:
          type: LoadBalancer
          loadBalancerIP: ${patches.value}
          loadBalancerSourceRanges: ${jsonencode(local.platform.gke_internal_source_ranges)}
      EOT
    }
  }

  # El backend vive fuera de este repositorio.
  kustomize_options {
    load_restrictor = "none"
  }

  lifecycle {
    precondition {
      condition     = fileexists("${local.backend_manifests}/kustomization.yaml")
      error_message = "No se encontró deploy/k8s/base del backend. Inicialice el submódulo components/backend o ajuste backend_path."
    }
  }
}

locals {
  ids_rendered = setunion(data.kustomization_overlay.backend.ids_prio[0], data.kustomization_overlay.backend.ids_prio[1], data.kustomization_overlay.backend.ids_prio[2])
  # Solo Services: nunca apps/* (Deployments) ni batch/* (Jobs).
  ids_services = toset([for id in local.ids_rendered : id if can(regex("^_/Service/", id))])
}

resource "kustomization_resource" "services" {
  for_each = local.ids_services

  manifest = data.kustomization_overlay.backend.manifests[each.value]

  depends_on = [kubernetes_namespace_v1.sportapp]
}

# --- RBAC de Cloud Deploy ----------------------------------------------------
#
# cloud-deploy-execution solo opera en este namespace: aplica Deployments y Jobs,
# observa su estado y consulta el readiness de las APIs por el proxy de sus
# Services. No borra, no lee Secrets ni ConfigMaps y no cambia RBAC, Services,
# KSA o la configuración que administra Terraform. IAM solo le da
# container.clusterViewer (credenciales del clúster, sin objetos).

resource "kubernetes_role_v1" "cloud_deploy" {
  metadata {
    name      = "cloud-deploy-execution"
    namespace = kubernetes_namespace_v1.sportapp.metadata[0].name
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["replicasets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "events"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }

  rule {
    api_groups     = [""]
    resources      = ["services/proxy"]
    resource_names = keys(local.internal_apis)
    verbs          = ["get"]
  }
}

resource "kubernetes_role_binding_v1" "cloud_deploy" {
  metadata {
    name      = "cloud-deploy-execution"
    namespace = kubernetes_namespace_v1.sportapp.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.cloud_deploy.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = local.deploy_execution
  }
}
