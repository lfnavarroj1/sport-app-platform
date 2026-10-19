# Credenciales: nunca llaves JSON.
# - Local: `gcloud auth application-default login` + impersonate_service_account.
# - Solo la estación del operador: ninguna automatización ni GitHub ejecuta esta raíz.
#
# La cuenta impersonada vive en el proyecto de gestión. Sin billing_project,
# algunas APIs (por ejemplo Service Networking al consultar sus operaciones)
# cobran la cuota a ese proyecto y fallan porque allí no están habilitadas.
provider "google" {
  project                     = var.project_id
  region                      = var.region
  impersonate_service_account = var.impersonate_service_account
  billing_project             = var.project_id
  user_project_override       = true
  default_labels              = local.labels
}
