# Comprueba, sin credenciales, que terraform.tfvars produce un plan válido
# y respeta las reglas del ambiente. Ejecutar: terraform init -backend=false && terraform test

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
}

# random no se simula: el mock aún no admite recursos efímeros y el proveedor
# real no tiene efectos externos.

variables {
  project_id                  = "sportapp-test"
  impersonate_service_account = null
}

run "terraform_tfvars_es_valido" {
  command = plan
}
