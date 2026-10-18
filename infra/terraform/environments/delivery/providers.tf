# Credenciales: nunca llaves JSON. Solo la estación del operador, con ADC e
# impersonación de tf-apply-production; GitHub, Cloud Build y Cloud Deploy no
# ejecutan esta raíz.
provider "google" {
  project                     = var.management_project_id
  region                      = var.region
  impersonate_service_account = var.impersonate_service_account
}
