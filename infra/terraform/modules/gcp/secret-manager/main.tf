# Contenedores de secretos de aplicación (JWT, OAuth de terceros, etc.).
# Terraform no conoce sus valores: se cargan fuera de banda con
#   gcloud secrets versions add <secreto> --data-file=-
# y cada carga solo recibe acceso a los secretos que declara.

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

variable "secrets" {
  description = "Secretos por id; accessors asigna miembros con clave estable."
  type = map(object({
    accessors = map(string)
  }))
}

locals {
  accessors = merge([
    for secret_id, secret in var.secrets : {
      for key, member in secret.accessors : "${secret_id}/${key}" => { secret_id = secret_id, member = member }
    }
  ]...)
}

resource "google_secret_manager_secret" "this" {
  for_each = var.secrets

  project   = var.project_id
  secret_id = each.key

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "accessors" {
  for_each = local.accessors

  project   = var.project_id
  secret_id = google_secret_manager_secret.this[each.value.secret_id].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value.member
}

output "secret_ids" {
  description = "Ids de los secretos creados."
  value       = sort(keys(google_secret_manager_secret.this))
}

output "accessor_bindings" {
  description = "Accesos concedidos como <secreto>/<carga>."
  value       = sort(keys(google_secret_manager_secret_iam_member.accessors))
}
