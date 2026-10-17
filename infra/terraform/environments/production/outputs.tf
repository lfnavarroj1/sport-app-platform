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
