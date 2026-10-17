output "artifact_registry_url" {
  description = "Prefijo para publicar y referenciar imágenes."
  value       = module.platform.artifact_registry_url
}

output "gke" {
  description = "Clúster GKE y namespace de SportApp."
  value       = module.platform.gke
}

output "gke_workload_identities" {
  description = "KSA -> cuenta GCP para la anotación iam.gke.io/gcp-service-account."
  value       = module.platform.gke_workload_identities
}

output "cloud_sql" {
  description = "Conexión de Cloud SQL y secretos de contraseña por usuario."
  value       = module.platform.cloud_sql
}

output "pubsub" {
  description = "Tópicos y suscripciones por dominio CQRS."
  value       = module.platform.pubsub
}

output "affiliation_pubsub" {
  description = "Mensajería de Afiliación (ADR-024): tópico de integración y alta gratuita."
  value       = module.platform.affiliation_pubsub
}

output "cloud_run_urls" {
  description = "URL de cada servicio Cloud Run."
  value       = module.platform.cloud_run_urls
}

output "service_accounts" {
  description = "Cuenta de servicio de cada carga."
  value       = module.platform.service_accounts
}

output "app_secret_ids" {
  description = "Secretos de aplicación pendientes de cargar con gcloud."
  value       = module.platform.app_secret_ids
}

output "integration_topics" {
  description = "Tópicos de integración de dominios no CQRS."
  value       = module.platform.integration_topics
}

output "gke_internal_apis" {
  description = "Service de GKE -> IP interna fija; la usa environments/production-workloads."
  value       = module.platform.gke_internal_apis
}

output "gke_internal_source_ranges" {
  description = "Rangos que pueden llegar a los balanceadores internos de GKE."
  value       = module.platform.gke_internal_source_ranges
}

output "runtime_config" {
  description = "Configuración no secreta del ConfigMap sportapp-runtime de GKE."
  value       = module.platform.runtime_config
}

output "cloud_run_env" {
  description = "Variables de entorno no secretas de cada servicio de Cloud Run."
  value       = module.platform.cloud_run_env
}
