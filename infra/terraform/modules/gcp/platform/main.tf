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
  # pubsub_names fija la suscripción y la DLQ que consume el backend (CMP-002) y
  # pubsub_max_delivery_attempts las entregas de su perfil; null usa los valores
  # por defecto del módulo pubsub y de var.pubsub.
  domains = {
    usuarios = {
      databases = ["usuarios_write", "usuarios_read"]
      cqrs      = true
      # HU001, CMP-001.
      pubsub_names = {
        projector_subscription = "proyector-usuarios-v1"
        dead_letter_topic      = "sportapp.usuarios.proyeccion.dlq"
      }
      pubsub_max_delivery_attempts = 5
    }
    afiliacion = { databases = ["afiliacion"], cqrs = false, pubsub_names = null, pubsub_max_delivery_attempts = null }
    servicios  = { databases = ["servicios"], cqrs = false, pubsub_names = null, pubsub_max_delivery_attempts = null }
    entrenamientos = {
      databases = ["entrenamientos_write", "entrenamientos_read"]
      cqrs      = true
      # HU010, CMP-003.
      pubsub_names = {
        projector_subscription = "proyector-entrenamientos-v1"
        dead_letter_topic      = "sportapp.entrenamientos.proyeccion.dlq"
      }
      pubsub_max_delivery_attempts = null
    }
    eventos = {
      databases = ["eventos_write", "eventos_read"]
      cqrs      = true
      # CMP-004: nombres que consume events-management-read-projector.
      pubsub_names = {
        projector_subscription = "proyector-eventos-v1"
        dead_letter_topic      = "sportapp.eventos.proyeccion.dlq"
      }
      pubsub_max_delivery_attempts = null
    }
  }

  # Tópicos de integración de dominios no CQRS: solo su publicador outbox
  # publica y no tienen suscripción mientras no exista un consumidor aprobado.
  # Afiliación (ADR-024) también consume usuario.registrado.v1 de Usuarios.
  integration_topics = {
    afiliacion = "sportapp.afiliacion.v1"
    servicios  = "sportapp.servicios.v1"
  }

  # Cargas de GKE. ksa coincide con el nombre del Deployment en backend/deploy/k8s;
  # las migraciones de cada dominio comparten la KSA <servicio>-migrate.
  gke_workloads = {
    users-api            = { ksa = "users-management", domain = "usuarios", kind = "api" }
    users-outbox         = { ksa = "users-management-outbox-publisher", domain = "usuarios", kind = "outbox" }
    users-projector      = { ksa = "users-management-read-projector", domain = "usuarios", kind = "projector" }
    users-migrate        = { ksa = "users-management-migrate", domain = "usuarios", kind = "migration" }
    affiliation-api      = { ksa = "affiliation-management", domain = "afiliacion", kind = "api" }
    affiliation-consumer = { ksa = "affiliation-management-free-plan-consumer", domain = "afiliacion", kind = "consumer" }
    affiliation-outbox   = { ksa = "affiliation-management-outbox-publisher", domain = "afiliacion", kind = "outbox" }
    affiliation-migrate  = { ksa = "affiliation-management-migrate", domain = "afiliacion", kind = "migration" }
    services-api         = { ksa = "complementary-services", domain = "servicios", kind = "api" }
    services-outbox      = { ksa = "complementary-services-outbox-publisher", domain = "servicios", kind = "outbox" }
    services-migrate     = { ksa = "complementary-services-migrate", domain = "servicios", kind = "migration" }
    training-api         = { ksa = "training-management", domain = "entrenamientos", kind = "api" }
    training-outbox      = { ksa = "training-management-outbox-publisher", domain = "entrenamientos", kind = "outbox" }
    training-projector   = { ksa = "training-management-read-projector", domain = "entrenamientos", kind = "projector" }
    training-migrate     = { ksa = "training-management-migrate", domain = "entrenamientos", kind = "migration" }
    events-api           = { ksa = "events-management", domain = "eventos", kind = "api" }
    events-outbox        = { ksa = "events-management-outbox-publisher", domain = "eventos", kind = "outbox" }
    events-projector     = { ksa = "events-management-read-projector", domain = "eventos", kind = "projector" }
    events-migrate       = { ksa = "events-management-migrate", domain = "eventos", kind = "migration" }
    third-party          = { ksa = "third-party-management", domain = null, kind = "api" }
  }

  # APIs de GKE que llaman los BFF de Cloud Run, por la variable que las nombra.
  # Cada una se expone con un balanceador interno en una IP fija reservada aquí.
  gke_internal_apis = {
    users-management       = "USERS_MANAGEMENT_BASE_URL"
    affiliation-management = "AFFILIATION_MANAGEMENT_BASE_URL"
    training-management    = "TRAINING_MANAGEMENT_BASE_URL"
    complementary-services = "COMPLEMENTARY_SERVICES_BASE_URL"
    events-management      = "EVENTS_MANAGEMENT_BASE_URL"
  }
  bff_upstreams = {
    bff-web    = keys(local.gke_internal_apis)
    bff-mobile = ["users-management", "affiliation-management", "training-management", "events-management"]
  }

  # Servicios de Cloud Run. El puerto web es provisional hasta que exista su imagen.
  cloud_run_services = {
    web        = { port = 8080, startup_probe_path = null, liveness_probe_path = null, vpc = false }
    bff-web    = { port = 8000, startup_probe_path = "/health/ready", liveness_probe_path = "/health/live", vpc = true }
    bff-mobile = { port = 8000, startup_probe_path = "/health/ready", liveness_probe_path = "/health/live", vpc = true }
  }

  # URL determinista de Cloud Run: permite que web y BFF se referencien sin ciclo.
  cloud_run_urls = { for name, s in local.cloud_run_services : name => "https://${name}-${data.google_project.this.number}.${var.region}.run.app" }

  # Configuración que la plataforma inyecta en Cloud Run; cloud_run_env la complementa.
  cloud_run_platform_env = {
    web = {
      BFF_WEB_BASE_URL              = local.cloud_run_urls["bff-web"]
      REGISTRATION_POLICIES_VERSION = var.app_config.registration_policies_version
      HEALTH_DATA_CONSENT_VERSION   = var.app_config.health_data_consent_version
    }
    bff-web = merge(
      { for api in local.bff_upstreams["bff-web"] : local.gke_internal_apis[api] => "http://${google_compute_address.gke_internal_api[api].address}" },
      { CORS_ALLOWED_ORIGINS = local.cloud_run_urls["web"] },
    )
    bff-mobile = { for api in local.bff_upstreams["bff-mobile"] : local.gke_internal_apis[api] => "http://${google_compute_address.gke_internal_api[api].address}" }
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

  project_id            = var.project_id
  project_number        = data.google_project.this.number
  domain                = each.key
  names                 = each.value.pubsub_names
  max_delivery_attempts = each.value.pubsub_max_delivery_attempts
  settings              = var.pubsub

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

# Tópicos de integración (afiliacion: HU001, ADR-024; servicios). Solo el
# publicador outbox de cada dominio publica en el suyo.
resource "google_pubsub_topic" "integration" {
  for_each = local.integration_topics

  project                    = var.project_id
  name                       = each.value
  message_retention_duration = var.pubsub.message_retention_duration

  depends_on = [module.project_services]
}

resource "google_pubsub_topic_iam_member" "integration_publishers" {
  for_each = {
    for key, w in local.gke_workloads : key => w
    if w.kind == "outbox" && contains(keys(local.integration_topics), coalesce(w.domain, "-"))
  }

  project = var.project_id
  topic   = google_pubsub_topic.integration[each.value.domain].name
  role    = "roles/pubsub.publisher"
  member  = module.iam.members[each.key]
}

# IP interna fija por API de GKE: el Service LoadBalancer interno del overlay
# de producción la toma, y los BFF de Cloud Run la reciben como URL.
resource "google_compute_address" "gke_internal_api" {
  for_each = local.gke_internal_apis

  project      = var.project_id
  region       = var.region
  name         = "${local.name_prefix}-${each.key}"
  address_type = "INTERNAL"
  subnetwork   = module.network.gke_subnetwork_id
}

module "free_plan_consumer" {
  source = "../pubsub-consumer"

  project_id        = var.project_id
  project_number    = data.google_project.this.number
  topic             = module.pubsub["usuarios"].topic
  subscription      = "sportapp.afiliacion.alta-gratuita.v1"
  dead_letter_topic = "sportapp.afiliacion.alta-gratuita.dlq"
  # R-19 (ADR-034): el tópico de Usuarios también transporta perfil.*.
  filter   = "attributes.event_type = \"usuario.registrado.v1\""
  settings = var.pubsub

  subscriber_members = {
    for key, w in local.gke_workloads : key => module.iam.members[key]
    if w.domain == "afiliacion" && w.kind == "consumer"
  }
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
  env                   = merge({ APP_ENV = var.environment }, local.cloud_run_platform_env[each.key], lookup(var.cloud_run_env, each.key, {}))
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
  consumer_subscriptions = concat(
    [for m in module.pubsub : m.projector_subscription],
    [module.free_plan_consumer.subscription],
  )

  depends_on = [module.project_services]
}
