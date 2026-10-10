terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.6"
    }
  }

  # Primera ejecución con estado local (ignorado por Git). Después puede
  # migrarse al bucket de gestión descomentando el bloque y ejecutando
  #   terraform init -migrate-state -backend-config="bucket=<bucket>"
  # backend "gcs" {
  #   prefix = "sportapp/bootstrap"
  # }
}

# Se ejecuta una sola vez con credenciales administrativas de una persona:
#   gcloud auth application-default login
# Las cuotas y presupuestos se facturan al proyecto de gestión.
provider "google" {
  project               = var.management_project_id
  region                = var.region
  billing_project       = var.management_project_id
  user_project_override = true
}
