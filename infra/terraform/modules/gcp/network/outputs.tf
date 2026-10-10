output "network_id" {
  description = "Identificador de la VPC."
  value       = google_compute_network.this.id
}

output "network_name" {
  description = "Nombre de la VPC."
  value       = google_compute_network.this.name
}

# Se toma de la conexión para que Cloud SQL espere a que el peering exista.
output "private_services_network" {
  description = "VPC con Private Services Access listo."
  value       = google_service_networking_connection.private_services.network
}

output "gke_subnetwork_id" {
  description = "Subred de nodos GKE."
  value       = google_compute_subnetwork.gke.id
}

output "gke_pods_range_name" {
  description = "Nombre del rango secundario de pods."
  value       = google_compute_subnetwork.gke.secondary_ip_range[0].range_name
}

output "gke_services_range_name" {
  description = "Nombre del rango secundario de Services."
  value       = google_compute_subnetwork.gke.secondary_ip_range[1].range_name
}

output "serverless_subnetwork_id" {
  description = "Subred para Direct VPC egress de Cloud Run."
  value       = google_compute_subnetwork.serverless.id
}
