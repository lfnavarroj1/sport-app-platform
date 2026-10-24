output "artifact_registry_urls" {
  description = "Prefijo de imágenes por repositorio: backend (APIs, workers y BFF) y frontend (web)."
  value       = { for key, m in module.artifact_registry : key => m.repository_url }
}

output "gke" {
  description = "Datos para obtener credenciales: gcloud container clusters get-credentials <name> --location <location> --dns-endpoint."
  value = {
    name         = module.gke.name
    location     = module.gke.location
    dns_endpoint = module.gke.dns_endpoint
    namespace    = var.gke_namespace
    cluster_id   = "projects/${var.project_id}/locations/${module.gke.location}/clusters/${module.gke.name}"
  }
}

output "delivery_identities" {
  description = "Identidades de entrega autorizadas en este ambiente (las lee environments/production-workloads para RBAC)."
  value       = var.delivery_identities
}

# Lo que environments/delivery necesita para declarar los targets de Cloud Run:
# la misma configuración que administra Terraform, como parámetros del target,
# para que un rollout solo cambie la imagen.
output "cloud_run_deploy_config" {
  description = "Por servicio de Cloud Run creado: ubicación, identidad, escalado, red y variables efectivas."
  value = {
    for name, m in module.cloud_run : name => {
      name            = m.name
      location        = "projects/${var.project_id}/locations/${var.region}"
      repository      = local.cloud_run_repository[name]
      service_account = module.iam.emails[name]
      port            = local.cloud_run_services[name].port
      cpu             = var.cloud_run.cpu
      memory          = var.cloud_run.memory
      min_instances   = var.suspended ? 0 : var.cloud_run.min_instances
      max_instances   = var.cloud_run.max_instances
      concurrency     = var.cloud_run.concurrency
      timeout_seconds = var.cloud_run.timeout_seconds
      vpc_network     = local.cloud_run_services[name].vpc ? local.cloud_run_vpc_network : null
      vpc_subnetwork  = local.cloud_run_services[name].vpc ? local.cloud_run_vpc_subnetwork : null
      env             = local.cloud_run_env_effective[name]
      secret_env      = lookup(var.cloud_run_secret_env, name, {})
      uri             = m.uri
    }
  }
}

output "gke_workload_identities" {
  description = "KSA -> cuenta GCP para la anotación iam.gke.io/gcp-service-account."
  value       = { for key, w in local.gke_workloads : w.ksa => module.iam.emails[key] }
}

output "cloud_sql" {
  description = "Conexión de Cloud SQL y secretos de contraseña por usuario."
  value = {
    instance_name    = module.cloud_sql.instance_name
    connection_name  = module.cloud_sql.connection_name
    private_ip       = module.cloud_sql.private_ip_address
    password_secrets = module.cloud_sql.password_secret_ids
  }
}

output "pubsub" {
  description = "Tópicos y suscripciones por dominio CQRS."
  value = {
    for domain, m in module.pubsub : domain => {
      topic                    = m.topic
      projector_subscription   = m.projector_subscription
      dead_letter_topic        = m.dead_letter_topic
      dead_letter_subscription = m.dead_letter_subscription
    }
  }
}

output "affiliation_pubsub" {
  description = "Mensajería de Afiliación (ADR-024): tópico de integración y alta gratuita."
  value = {
    topic                       = google_pubsub_topic.integration["afiliacion"].name
    free_plan_subscription      = module.free_plan_consumer.subscription
    free_plan_dead_letter_topic = module.free_plan_consumer.dead_letter_topic
    free_plan_dead_letter_ops   = module.free_plan_consumer.dead_letter_subscription
  }
}

output "integration_topics" {
  description = "Tópicos de integración de dominios no CQRS."
  value       = { for domain, t in google_pubsub_topic.integration : domain => t.name }
}

# Entradas no secretas de environments/production-workloads.
output "gke_internal_apis" {
  description = "Service de GKE -> IP interna fija de su balanceador interno."
  value       = { for name, a in google_compute_address.gke_internal_api : name => a.address }
}

output "gke_internal_source_ranges" {
  description = "Rangos que pueden llegar a los balanceadores internos: la subred de Cloud Run."
  value       = [var.network.serverless_cidr]
}

output "runtime_config" {
  description = "Configuración no secreta del ConfigMap sportapp-runtime de GKE."
  value = {
    app_env                              = var.environment
    project_id                           = var.project_id
    database_host                        = module.cloud_sql.private_ip_address
    registration_policies_version        = var.app_config.registration_policies_version
    health_data_consent_version          = var.app_config.health_data_consent_version
    affiliation_expected_catalog_version = var.app_config.affiliation_expected_catalog_version
  }
}

output "cloud_run_env" {
  description = "Variables de entorno no secretas de cada servicio de Cloud Run (las de la plataforma más cloud_run_env)."
  value       = local.cloud_run_env_effective
}

output "cloud_run_urls" {
  description = "URL de cada servicio desplegado."
  value       = { for name, m in module.cloud_run : name => m.uri }
}

output "service_accounts" {
  description = "Cuenta de servicio de cada carga, por clave lógica."
  value       = module.iam.emails
}

output "app_secret_ids" {
  description = "Secretos de aplicación pendientes de cargar con gcloud."
  value       = module.app_secrets.secret_ids
}
