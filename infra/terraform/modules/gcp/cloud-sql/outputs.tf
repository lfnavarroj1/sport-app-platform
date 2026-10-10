output "instance_name" {
  description = "Nombre de la instancia."
  value       = google_sql_database_instance.this.name
}

output "connection_name" {
  description = "proyecto:región:instancia, para Cloud SQL Auth Proxy."
  value       = google_sql_database_instance.this.connection_name
}

output "private_ip_address" {
  description = "IP privada de la instancia."
  value       = google_sql_database_instance.this.private_ip_address
}

output "password_secret_ids" {
  description = "Secreto de contraseña por usuario."
  value       = { for user, secret in google_secret_manager_secret.passwords : user => secret.secret_id }
}
