# Cargas de SportApp en el GKE de producción (vista de despliegue): APIs,
# publicadores outbox, proyectores CQRS, consumidor del alta gratuita y Jobs de
# migración, a partir de deploy/k8s/base del backend. web, bff-web y bff-mobile
# corren en Cloud Run y los crea environments/production.
#
# Esta raíz tiene estado propio y depende de environments/production: lee de su
# estado el clúster, las identidades, la IP de Cloud SQL, las IP internas de las
# APIs y la configuración no secreta. Las contraseñas y la clave JWT se copian
# de Secret Manager con valores efímeros; no quedan en el estado.

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

  gke_components = [
    "users-management",
    "affiliation-management",
    "complementary-services",
    "training-management",
    "events-management",
    "third-party-management",
  ]

  # KSA -> cuenta GCP (Workload Identity). Las KSA <servicio>-migrate son de los
  # Jobs de migración; las demás tienen el nombre de su Deployment.
  identities       = local.platform.gke_workload_identities
  migration_ksas   = toset([for ksa in keys(local.identities) : ksa if endswith(ksa, "-migrate")])
  deployment_ksas  = toset([for ksa in keys(local.identities) : ksa if !endswith(ksa, "-migrate")])
  api_deployments  = toset(local.gke_components)
  cloud_run_owners = toset(["bff-web", "bff-mobile"])

  # Usuario PostgreSQL (dominio) -> clave del Secret sportapp-database.
  database_passwords = { for domain, secret in local.platform.cloud_sql.password_secrets : "${upper(domain)}_DB_PASSWORD" => secret }
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

data "kustomization_overlay" "backend" {
  namespace = local.namespace
  resources = [local.backend_manifests]

  config_map_generator {
    name = "sportapp-runtime"
    literals = [
      "APP_ENV=${local.runtime.app_env}",
      "LOG_LEVEL=${var.log_level}",
      # IP privada de Cloud SQL; la instancia exige TLS y libpq lo negocia.
      "DATABASE_HOST=${local.runtime.database_host}",
      "REGISTRATION_POLICIES_VERSION=${local.runtime.registration_policies_version}",
      "HEALTH_DATA_CONSENT_VERSION=${local.runtime.health_data_consent_version}",
      "AFFILIATION_EXPECTED_CATALOG_VERSION=${local.runtime.affiliation_expected_catalog_version}",
      "USERS_MANAGEMENT_BASE_URL=http://users-management",
      # Pub/Sub administrado: sin PUBSUB_EMULATOR_HOST.
      "PUBSUB_PROJECT_ID=${local.runtime.project_id}",
    ]
  }

  # Imágenes de Artifact Registry fijadas por digest.
  dynamic "images" {
    for_each = toset(local.gke_components)
    content {
      name     = "sportapp/${images.value}"
      new_name = "${local.platform.artifact_registry_url}/${images.value}"
      digest   = var.image_digests[images.value]
    }
  }

  # web, bff-web y bff-mobile corren en Cloud Run.
  dynamic "patches" {
    for_each = {
      for pair in setproduct(local.cloud_run_owners, [{ api = "apps/v1", kind = "Deployment" }, { api = "v1", kind = "Service" }]) :
      "${pair[1].kind}/${pair[0]}" => { name = pair[0], api = pair[1].api, kind = pair[1].kind }
    }
    content {
      patch = <<-EOT
        $patch: delete
        apiVersion: ${patches.value.api}
        kind: ${patches.value.kind}
        metadata:
          name: ${patches.value.name}
      EOT
    }
  }

  # Cada Deployment usa la KSA de su nombre (Workload Identity).
  dynamic "patches" {
    for_each = local.deployment_ksas
    content {
      target {
        kind = "Deployment"
        name = patches.value
      }
      patch = <<-EOT
        - op: add
          path: /spec/template/spec/serviceAccountName
          value: ${patches.value}
      EOT
    }
  }

  # Los Jobs de migración de un servicio comparten la KSA <servicio>-migrate.
  dynamic "patches" {
    for_each = local.migration_ksas
    content {
      target {
        kind = "Job"
        name = "${patches.value}-.*"
      }
      patch = <<-EOT
        - op: add
          path: /spec/template/spec/serviceAccountName
          value: ${patches.value}
      EOT
    }
  }

  # Réplicas de las APIs; publicadores, proyectores y consumidores conservan las
  # del backend, acotadas por el presupuesto de conexiones de Cloud SQL.
  dynamic "patches" {
    for_each = local.api_deployments
    content {
      target {
        kind = "Deployment"
        name = patches.value
      }
      patch = <<-EOT
        - op: replace
          path: /spec/replicas
          value: ${var.api_replicas}
      EOT
    }
  }

  # APIs que llaman los BFF de Cloud Run: balanceador interno en la IP reservada
  # por environments/production, alcanzable solo desde la subred de Cloud Run.
  # Dentro del clúster se siguen llamando por su nombre (http://<servicio>).
  dynamic "patches" {
    for_each = local.platform.gke_internal_apis
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

  # ADR-036: el catálogo esperado viene de sportapp-runtime, como en local.
  patches {
    target {
      kind = "Deployment"
      name = "affiliation-management"
    }
    patch = <<-EOT
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: affiliation-management
      spec:
        template:
          spec:
            containers:
              - name: app
                env:
                  - name: AFFILIATION_EXPECTED_CATALOG_VERSION
                    value: null
                    valueFrom:
                      configMapKeyRef:
                        name: sportapp-runtime
                        key: AFFILIATION_EXPECTED_CATALOG_VERSION
    EOT
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

# Fases: configuración y Services -> migraciones completas -> cargas.
locals {
  ids          = setunion(data.kustomization_overlay.backend.ids_prio[0], data.kustomization_overlay.backend.ids_prio[1], data.kustomization_overlay.backend.ids_prio[2])
  ids_jobs     = toset([for id in local.ids : id if can(regex("^batch/Job/", id))])
  ids_workload = toset([for id in local.ids : id if can(regex("^apps/", id))])
  ids_config   = setsubtract(local.ids, setunion(local.ids_jobs, local.ids_workload))
}

resource "kustomization_resource" "config" {
  for_each = local.ids_config

  manifest = data.kustomization_overlay.backend.manifests[each.value]

  depends_on = [kubernetes_namespace_v1.sportapp]
}

# Un Job es inmutable: un manifiesto nuevo (por ejemplo, otro digest) lo reemplaza.
resource "terraform_data" "migration_revision" {
  for_each = local.ids_jobs

  input = sha256(data.kustomization_overlay.backend.manifests[each.value])
}

# Terraform espera a que cada migración termine (ADR-024: el catálogo de
# Afiliación debe existir antes de sus réplicas). Un Job fallido detiene el apply.
resource "kubernetes_manifest" "migration" {
  for_each = local.ids_jobs

  manifest = jsondecode(data.kustomization_overlay.backend.manifests[each.value])

  # Campos que completa el controlador de Jobs.
  computed_fields = ["metadata.labels", "metadata.annotations", "spec.selector", "spec.template.metadata.labels"]

  wait {
    condition {
      type   = "Complete"
      status = "True"
    }
  }

  timeouts {
    create = var.migration_timeout
    update = var.migration_timeout
  }

  lifecycle {
    replace_triggered_by = [terraform_data.migration_revision[each.key]]
  }

  depends_on = [
    kustomization_resource.config,
    kubernetes_secret_v1.database,
    kubernetes_service_account_v1.workload,
  ]
}

resource "kustomization_resource" "workloads" {
  for_each = local.ids_workload

  manifest = data.kustomization_overlay.backend.manifests[each.value]
  wait     = true

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    kustomization_resource.config,
    kubernetes_manifest.migration,
    kubernetes_secret_v1.database,
    kubernetes_secret_v1.users_jwt,
    kubernetes_service_account_v1.workload,
  ]
}
