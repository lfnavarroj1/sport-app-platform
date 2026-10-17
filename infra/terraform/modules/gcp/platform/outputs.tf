output "artifact_registry_url" {
  description = "Prefijo para publicar y referenciar imágenes."
  value       = module.artifact_registry.repository_url
}

output "gke" {
  description = "Datos para obtener credenciales: gcloud container clusters get-credentials <name> --location <location> --dns-endpoint."
  value = {
    name         = module.gke.name
    location     = module.gke.location
    dns_endpoint = module.gke.dns_endpoint
    namespace    = var.gke_namespace
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
  value       = { for name, s in local.cloud_run_services : name => merge({ APP_ENV = var.environment }, local.cloud_run_platform_env[name], lookup(var.cloud_run_env, name, {})) }
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
