# Composición completa de un ambiente GCP de SportApp. Las raíces de
# environments/ solo eligen tamaños; la topología es la misma en todos los
# ambientes para que desarrollo sea representativo de producción.

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.6"
    }
  }
}

locals {
  short_env   = { development = "dev", staging = "stg", production = "prod" }[var.environment]
  name_prefix = "sportapp-${local.short_env}"

  # Almacenes lógicos por dominio (arquitectura/04-datos-y-persistencia.md).
  # El nombre del dominio es también el usuario PostgreSQL y el sufijo del tópico.
  domains = {
    usuarios       = { databases = ["usuarios_write", "usuarios_read"], cqrs = true }
    afiliacion     = { databases = ["afiliacion"], cqrs = false }
    servicios      = { databases = ["servicios"], cqrs = false }
    entrenamientos = { databases = ["entrenamientos_write", "entrenamientos_read"], cqrs = true }
    eventos        = { databases = ["eventos_write", "eventos_read"], cqrs = true }
  }

  # Cargas de GKE. ksa coincide con el nombre del Deployment en backend/deploy/k8s.
  gke_workloads = {
    users-api          = { ksa = "users-management", domain = "usuarios", kind = "api" }
    users-outbox       = { ksa = "users-management-outbox-publisher", domain = "usuarios", kind = "outbox" }
    users-projector    = { ksa = "users-management-read-projector", domain = "usuarios", kind = "projector" }
    affiliation-api    = { ksa = "affiliation-management", domain = "afiliacion", kind = "api" }
    services-api       = { ksa = "complementary-services", domain = "servicios", kind = "api" }
    training-api       = { ksa = "training-management", domain = "entrenamientos", kind = "api" }
    training-outbox    = { ksa = "training-management-outbox-publisher", domain = "entrenamientos", kind = "outbox" }
    training-projector = { ksa = "training-management-read-projector", domain = "entrenamientos", kind = "projector" }
    events-api         = { ksa = "events-management", domain = "eventos", kind = "api" }
    events-outbox      = { ksa = "events-management-outbox-publisher", domain = "eventos", kind = "outbox" }
    events-projector   = { ksa = "events-management-read-projector", domain = "eventos", kind = "projector" }
    third-party        = { ksa = "third-party-management", domain = null, kind = "api" }
  }

  # Servicios de Cloud Run. El puerto web es provisional hasta que exista su imagen.
  cloud_run_services = {
    web        = { port = 8080, startup_probe_path = null, liveness_probe_path = null, vpc = false }
    bff-web    = { port = 8000, startup_probe_path = "/health/ready", liveness_probe_path = "/health/live", vpc = true }
    bff-mobile = { port = 8000, startup_probe_path = "/health/ready", liveness_probe_path = "/health/live", vpc = true }
  }

  service_accounts = merge(
    {
      for key, w in local.gke_workloads : key => {
        account_id    = "gke-${key}"
        display_name  = "GKE ${w.ksa}"
        project_roles = w.domain == null ? [] : ["roles/cloudsql.client"]
        gke_ksa       = w.ksa
      }
    },
    {
      for key, s in local.cloud_run_services : key => {
        account_id    = "run-${key}"
        display_name  = "Cloud Run ${key}"
        project_roles = []
        gke_ksa       = null
      }
    }
  )
}

data "google_project" "this" {
  project_id = var.project_id
}

module "project_services" {
  source = "../project-services"

  project_id = var.project_id
  services = [
    "artifactregistry.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
  ]
}

module "network" {
  source = "../network"

  project_id                     = var.project_id
  region                         = var.region
  name_prefix                    = local.name_prefix
  subnet_cidr                    = var.network.subnet_cidr
  pods_cidr                      = var.network.pods_cidr
  services_cidr                  = var.network.services_cidr
  serverless_cidr                = var.network.serverless_cidr
  private_services_prefix_length = var.network.private_services_prefix_length
  flow_logs_sampling             = var.network.flow_logs_sampling

  depends_on = [module.project_services]
}

module "gke" {
  source = "../gke"

  project_id                 = var.project_id
  name                       = "${local.name_prefix}-gke"
  location                   = var.gke.location
  network                    = module.network.network_id
  subnetwork                 = module.network.gke_subnetwork_id
  pods_range_name            = module.network.gke_pods_range_name
  services_range_name        = module.network.gke_services_range_name
  release_channel            = var.gke.release_channel
  master_authorized_networks = var.gke_authorized_networks
  deletion_protection        = var.deletion_protection
  suspended                  = var.suspended
  labels                     = var.labels

  node_pool = {
    machine_type = var.gke.machine_type
    spot         = var.gke.spot
    min_nodes    = var.gke.min_nodes
    max_nodes    = var.gke.max_nodes
    disk_size_gb = var.gke.disk_size_gb
  }
}

module "iam" {
  source = "../iam"

  project_id       = var.project_id
  service_accounts = local.service_accounts
  gke_namespace    = var.gke_namespace
  workload_pool    = module.gke.workload_pool
}

module "artifact_registry" {
  source = "../artifact-registry"

  project_id                 = var.project_id
  region                     = var.region
  repository_id              = var.artifact_registry.repository_id
  immutable_tags             = var.artifact_registry.immutable_tags
  keep_recent_versions       = var.artifact_registry.keep_recent_versions
  delete_untagged_after_days = var.artifact_registry.delete_untagged_after_days
  cleanup_dry_run            = var.artifact_registry.cleanup_dry_run
  reader_members             = { gke-nodes = module.gke.node_service_account_member }
  writer_members             = var.artifact_registry_writers

  depends_on = [module.project_services]
}

module "cloud_sql" {
  source = "../cloud-sql"

  project_id               = var.project_id
  region                   = var.region
  name_prefix              = local.name_prefix
  private_network          = module.network.private_services_network
  database_version         = var.cloud_sql.database_version
  tier                     = var.cloud_sql.tier
  availability_type        = var.cloud_sql.availability_type
  disk_size_gb             = var.cloud_sql.disk_size_gb
  disk_autoresize_limit_gb = var.cloud_sql.disk_autoresize_limit_gb
  databases                = toset(flatten([for d in local.domains : d.databases]))
  users                    = toset(keys(local.domains))
  password_version         = var.cloud_sql.password_version
  stopped                  = var.suspended
  deletion_protection      = var.deletion_protection
  labels                   = var.labels

  backups = {
    enabled                        = var.cloud_sql.backups_enabled
    point_in_time_recovery         = var.cloud_sql.point_in_time_recovery
    retained_backups               = var.cloud_sql.retained_backups
    transaction_log_retention_days = var.cloud_sql.transaction_log_retention_days
  }
}

# Cada carga solo lee la contraseña del usuario de su dominio.
resource "google_secret_manager_secret_iam_member" "db_password" {
  for_each = { for key, w in local.gke_workloads : key => w if w.domain != null }

  project   = var.project_id
  secret_id = module.cloud_sql.password_secret_ids[each.value.domain]
  role      = "roles/secretmanager.secretAccessor"
  member    = module.iam.members[each.key]
}

module "pubsub" {
  source   = "../pubsub"
  for_each = { for name, d in local.domains : name => d if d.cqrs }

  project_id     = var.project_id
  project_number = data.google_project.this.number
  domain         = each.key
  settings       = var.pubsub

  publisher_members = {
    for key, w in local.gke_workloads : key => module.iam.members[key]
    if w.domain == each.key && w.kind == "outbox"
  }
  subscriber_members = {
    for key, w in local.gke_workloads : key => module.iam.members[key]
    if w.domain == each.key && w.kind == "projector"
  }

  depends_on = [module.project_services]
}

module "app_secrets" {
  source = "../secret-manager"

  project_id = var.project_id
  secrets = {
    for id, secret in var.app_secrets : id => {
      accessors = merge(
        { for key in secret.accessors : key => module.iam.members[key] },
        { for svc, env in var.cloud_run_secret_env : svc => module.iam.members[svc] if contains(values(env), id) },
      )
    }
  }

  depends_on = [module.project_services]
}

module "cloud_run" {
  source   = "../cloud-run"
  for_each = { for name, s in local.cloud_run_services : name => s if contains(keys(var.cloud_run_images), name) }

  project_id            = var.project_id
  region                = var.region
  name                  = each.key
  image                 = var.cloud_run_images[each.key]
  service_account       = module.iam.emails[each.key]
  port                  = each.value.port
  cpu                   = var.cloud_run.cpu
  memory                = var.cloud_run.memory
  min_instances         = var.suspended ? 0 : var.cloud_run.min_instances
  max_instances         = var.cloud_run.max_instances
  concurrency           = var.cloud_run.concurrency
  timeout_seconds       = var.cloud_run.timeout_seconds
  allow_unauthenticated = contains(var.cloud_run_public_services, each.key)
  env                   = merge({ APP_ENV = var.environment }, lookup(var.cloud_run_env, each.key, {}))
  secret_env            = lookup(var.cloud_run_secret_env, each.key, {})
  vpc_network           = each.value.vpc ? module.network.network_id : null
  vpc_subnetwork        = each.value.vpc ? module.network.serverless_subnetwork_id : null
  startup_probe_path    = each.value.startup_probe_path
  liveness_probe_path   = each.value.liveness_probe_path
  deletion_protection   = var.deletion_protection

  depends_on = [module.app_secrets]
}

module "observability" {
  source = "../observability"

  project_id          = var.project_id
  environment         = var.environment
  notification_emails = var.alert_emails

  depends_on = [module.project_services]
}
