# Una cuenta de servicio por carga. Las cargas de GKE la obtienen por Workload
# Identity (KSA -> GSA); ninguna usa llaves JSON. Los permisos sobre recursos
# concretos (tópicos, suscripciones, secretos) los otorga el módulo dueño del recurso.

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

variable "service_accounts" {
  description = "Cuentas por clave lógica. gke_ksa enlaza la cuenta con una KSA del namespace."
  type = map(object({
    account_id    = string
    display_name  = string
    project_roles = optional(set(string), [])
    gke_ksa       = optional(string)
  }))
}

variable "gke_namespace" {
  description = "Namespace de Kubernetes donde viven las KSA."
  type        = string
}

variable "workload_pool" {
  description = "Pool de Workload Identity del clúster (<proyecto>.svc.id.goog)."
  type        = string
}

locals {
  project_roles = merge([
    for key, sa in var.service_accounts : {
      for role in sa.project_roles : "${key}/${role}" => { key = key, role = role }
    }
  ]...)
}

resource "google_service_account" "this" {
  for_each = var.service_accounts

  project      = var.project_id
  account_id   = each.value.account_id
  display_name = each.value.display_name
}

resource "google_project_iam_member" "this" {
  for_each = local.project_roles

  project = var.project_id
  role    = each.value.role
  member  = google_service_account.this[each.value.key].member
}

resource "google_service_account_iam_member" "workload_identity" {
  for_each = { for key, sa in var.service_accounts : key => sa if sa.gke_ksa != null }

  service_account_id = google_service_account.this[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.workload_pool}[${var.gke_namespace}/${each.value.gke_ksa}]"
}

output "emails" {
  description = "Correo de cada cuenta por clave lógica."
  value       = { for key, sa in google_service_account.this : key => sa.email }
}

output "members" {
  description = "Miembro IAM (serviceAccount:...) por clave lógica."
  value       = { for key, sa in google_service_account.this : key => sa.member }
}
