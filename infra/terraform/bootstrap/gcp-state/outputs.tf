output "state_buckets" {
  description = "Bucket de estado por ambiente (valor de bucket en backend.hcl)."
  value       = { for env, b in google_storage_bucket.state : env => b.name }
}

output "plan_service_accounts" {
  description = "Cuenta tf-plan por ambiente."
  value       = { for env, sa in google_service_account.plan : env => sa.email }
}

output "apply_service_accounts" {
  description = "Cuenta tf-apply por ambiente (impersonate_service_account en local)."
  value       = { for env, sa in google_service_account.apply : env => sa.email }
}

output "delivery_service_accounts" {
  description = "Cuenta ci-delivery por ambiente (GCP_DELIVERY_SERVICE_ACCOUNT en backend/frontend)."
  value       = { for env, sa in google_service_account.delivery : env => sa.email }
}

output "workload_identity_provider" {
  description = "Valor de workload_identity_provider para google-github-actions/auth."
  value       = google_iam_workload_identity_pool_provider.github.name
}
