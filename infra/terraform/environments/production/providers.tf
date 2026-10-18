# Credenciales: nunca llaves JSON.
# - Local: `gcloud auth application-default login` + impersonate_service_account.
# - Solo la estación del operador: ninguna automatización ni GitHub ejecuta esta raíz.
provider "google" {
  project                     = var.project_id
  region                      = var.region
  impersonate_service_account = var.impersonate_service_account
  default_labels              = local.labels
}
