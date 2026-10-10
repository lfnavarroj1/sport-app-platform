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
      dead_letter_subscription = m.dead_letter_subscription
    }
  }
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
