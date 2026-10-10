output "name" {
  description = "Nombre del clúster."
  value       = google_container_cluster.this.name
}

output "location" {
  description = "Zona o región del clúster."
  value       = google_container_cluster.this.location
}

output "dns_endpoint" {
  description = "Endpoint DNS del plano de control (acceso autorizado con IAM)."
  value       = google_container_cluster.this.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint
}

# Tomarlo del clúster garantiza que el pool exista antes de crear enlaces de Workload Identity.
output "workload_pool" {
  description = "Pool de Workload Identity."
  value       = google_container_cluster.this.workload_identity_config[0].workload_pool
}

output "node_service_account_member" {
  description = "Miembro IAM de la cuenta de los nodos."
  value       = google_service_account.nodes.member
}
