output "state_buckets" {
  description = "Bucket de estado por ambiente (valor de bucket en backend.hcl)."
  value       = { for env, b in google_storage_bucket.state : env => b.name }
}

output "plan_service_accounts" {
  description = "Cuenta tf-plan por ambiente: planes manuales de lectura, solo operadores."
  value       = { for env, sa in google_service_account.plan : env => sa.email }
}

output "apply_service_accounts" {
  description = "Cuenta tf-apply por ambiente (impersonate_service_account en la estación del operador)."
  value       = { for env, sa in google_service_account.apply : env => sa.email }
}

output "delivery_identities" {
  description = "Identidades internas de entrega: valor de delivery_identities en environments/production y environments/delivery."
  value       = { for key, sa in google_service_account.delivery : key => sa.email }
}
