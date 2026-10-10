# Repositorio Docker del ambiente. Las imágenes se despliegan por digest y los
# tags son inmutables; la limpieza evita costos por imágenes huérfanas.

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

variable "region" {
  description = "Ubicación del repositorio."
  type        = string
}

variable "repository_id" {
  description = "Nombre del repositorio."
  type        = string
}

variable "immutable_tags" {
  description = "Impide reasignar un tag existente a otro digest."
  type        = bool
  default     = true
}

variable "keep_recent_versions" {
  description = "Versiones recientes que la limpieza conserva por imagen."
  type        = number
}

variable "delete_untagged_after_days" {
  description = "Días tras los cuales se borran imágenes sin tag."
  type        = number
}

variable "cleanup_dry_run" {
  description = "Si es true, la política de limpieza solo informa."
  type        = bool
  default     = false
}

# Las claves deben ser estáticas: el miembro puede conocerse solo después de aplicar.
variable "reader_members" {
  description = "Miembros con roles/artifactregistry.reader, por clave estable."
  type        = map(string)
  default     = {}
}

variable "writer_members" {
  description = "Miembros con roles/artifactregistry.writer (pipelines de componentes)."
  type        = map(string)
  default     = {}
}

resource "google_artifact_registry_repository" "this" {
  project                = var.project_id
  location               = var.region
  repository_id          = var.repository_id
  description            = "Imágenes OCI de SportApp"
  format                 = "DOCKER"
  cleanup_policy_dry_run = var.cleanup_dry_run

  docker_config {
    immutable_tags = var.immutable_tags
  }

  cleanup_policies {
    id     = "borrar-sin-tag"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "${var.delete_untagged_after_days * 86400}s"
    }
  }

  cleanup_policies {
    id     = "conservar-recientes"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.keep_recent_versions
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each = var.reader_members

  project    = var.project_id
  location   = google_artifact_registry_repository.this.location
  repository = google_artifact_registry_repository.this.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

resource "google_artifact_registry_repository_iam_member" "writers" {
  for_each = var.writer_members

  project    = var.project_id
  location   = google_artifact_registry_repository.this.location
  repository = google_artifact_registry_repository.this.name
  role       = "roles/artifactregistry.writer"
  member     = each.value
}

output "repository_url" {
  description = "Prefijo de imágenes: <región>-docker.pkg.dev/<proyecto>/<repositorio>."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.this.repository_id}"
}
