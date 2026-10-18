variable "management_project_id" {
  description = "Proyecto de gestión: Cloud Build, Cloud Deploy y evidencia de releases."
  type        = string
}

variable "region" {
  description = "Región del plano de entrega (triggers, conexión y pipelines)."
  type        = string
  default     = "us-central1"
}

variable "impersonate_service_account" {
  description = "Cuenta tf-apply-production (o tf-plan-production para revisar) que el operador impersona desde su estación."
  type        = string

  validation {
    condition     = can(regex("^tf-(apply|plan)-production@[a-z][a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", var.impersonate_service_account))
    error_message = "Esta raíz se ejecuta impersonando tf-apply-production o tf-plan-production."
  }
}

variable "state_bucket" {
  description = "Bucket de estado de producción (state_buckets.production del bootstrap); de él se leen los recursos destino."
  type        = string
}

variable "delivery_identities" {
  description = "Salida delivery_identities del bootstrap."
  type = object({
    build_backend    = string
    build_frontend   = string
    release_promoter = string
    deploy_execution = string
  })

  validation {
    condition     = length(distinct(values(var.delivery_identities))) == 4 && alltrue([for email in values(var.delivery_identities) : !startswith(email, "tf-")])
    error_message = "Las cuatro identidades de entrega son distintas y ninguna es una cuenta de Terraform."
  }
}

variable "github_repositories" {
  description = "Repositorios que GCP lee mediante la GitHub App de Cloud Build (propietario/nombre). GitHub no recibe identidad GCP."
  type = object({
    backend  = string
    frontend = string
    platform = string
  })
  default = {
    backend  = "lfnavarroj1/sport-app-backend"
    frontend = "lfnavarroj1/sport-app-frontend"
    platform = "lfnavarroj1/sport-app-platform"
  }
}

variable "github_connection_ready" {
  description = "true después de autorizar la GitHub App en la conexión (paso manual documentado): crea los repositorios vinculados y los triggers."
  type        = bool
  default     = false
}

variable "release_triggers_enabled" {
  description = "Habilita release-backend y release-frontend. Mantener en false hasta que la conexión esté autorizada y ambos repositorios tengan cloudbuild.release.yaml."
  type        = bool
  default     = false

  validation {
    condition     = !var.release_triggers_enabled || var.github_connection_ready
    error_message = "Los triggers de release requieren la conexión autorizada (github_connection_ready = true)."
  }
}

variable "release_tag_pattern" {
  description = "Tags que publican una release (SemVer vX.Y.Z o vX.Y.Z-pre)."
  type        = string
  default     = "^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$"
}

variable "approvers" {
  description = "Personas o grupos que aprueban rollouts de producción (roles/clouddeploy.approver en cada pipeline)."
  type        = list(string)

  validation {
    condition     = length(var.approvers) > 0 && alltrue([for m in var.approvers : can(regex("^(user|group):[^@\\s]+@[^@\\s]+$", m))])
    error_message = "approvers solo admite user: o group:. Cloud Build, release-promoter, cloud-deploy-execution, Terraform y las cuentas de carga no aprueban rollouts."
  }
}

variable "deploy_tools_image" {
  description = "Imagen por digest con gcloud, kubectl y gke-gcloud-auth-plugin para las verificaciones de GKE (migraciones y smoke)."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9.-]+(/[a-z0-9._-]+)+(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$", var.deploy_tools_image)) && !strcontains(var.deploy_tools_image, ":latest@")
    error_message = "La imagen de herramientas se fija por digest sha256 y nunca usa latest."
  }
}

variable "run_verify_image" {
  description = "Imagen por digest con gcloud y curl para los smoke tests de Cloud Run."
  type        = string
  default     = "gcr.io/google.com/cloudsdktool/google-cloud-cli:588.0.0-slim@sha256:cde9dbd556000c21c08449d8e5828904ef91e690bec95207f71fa6a6685922c9"

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.run_verify_image)) && !strcontains(var.run_verify_image, ":latest@")
    error_message = "La imagen de verificación se fija por digest sha256."
  }
}

variable "promoter_image" {
  description = "Imagen por digest con gcloud, python3 y git para scripts/promote_release.py."
  type        = string
  default     = "gcr.io/google.com/cloudsdktool/google-cloud-cli:588.0.0-slim@sha256:cde9dbd556000c21c08449d8e5828904ef91e690bec95207f71fa6a6685922c9"

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.promoter_image)) && !strcontains(var.promoter_image, ":latest@")
    error_message = "La imagen del promotor se fija por digest sha256."
  }
}

variable "evidence_retention_days" {
  description = "Días que se conserva cada versión de un manifiesto de release."
  type        = number
  default     = 730

  validation {
    condition     = var.evidence_retention_days >= 365
    error_message = "La evidencia de releases se conserva al menos un año."
  }
}

variable "evidence_kms_key" {
  description = "Llave KMS (CMEK) para la evidencia; null usa el cifrado administrado por Google."
  type        = string
  default     = null
}
