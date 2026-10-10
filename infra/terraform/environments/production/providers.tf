# Credenciales: nunca llaves JSON.
# - Local: `gcloud auth application-default login` + impersonate_service_account.
# - CI: google-github-actions/auth con Workload Identity Federation (sin impersonación).
provider "google" {
  project                     = var.project_id
  region                      = var.region
  impersonate_service_account = var.impersonate_service_account
  default_labels              = local.labels
}
