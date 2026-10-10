# Habilita las APIs que necesita un proyecto de ambiente.
# No las deshabilita al destruir: otro estado o una persona podría depender de ellas.

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.6"
    }
  }
}

variable "project_id" {
  description = "Proyecto GCP del ambiente."
  type        = string
}

variable "services" {
  description = "APIs a habilitar, por ejemplo container.googleapis.com."
  type        = set(string)
}

resource "google_project_service" "this" {
  for_each = var.services

  project                    = var.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}

output "services" {
  description = "APIs habilitadas."
  value       = sort([for s in google_project_service.this : s.service])
}
