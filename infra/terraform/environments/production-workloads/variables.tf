variable "project_id" {
  description = "Proyecto GCP de producción (el mismo de environments/production)."
  type        = string
}

variable "region" {
  description = "Región de producción."
  type        = string
  default     = "us-central1"
}

variable "impersonate_service_account" {
  description = "Cuenta a impersonar en local (tf-plan- o tf-apply-production); null en CI con WIF."
  type        = string
  default     = null
}

variable "state_bucket" {
  description = "Bucket de estado creado por el bootstrap; de él se leen las salidas de environments/production."
  type        = string
}

variable "backend_path" {
  description = "Carpeta del repositorio backend, relativa a esta carpeta (submódulo por defecto)."
  type        = string
  default     = "../../../../components/backend"
}

variable "image_digests" {
  description = "Digest sha256 de cada componente del backend que corre en GKE, tomado de release-manifest.yaml."
  type        = map(string)

  validation {
    condition = alltrue([
      for c in ["users-management", "affiliation-management", "complementary-services", "training-management", "events-management", "third-party-management"] :
      can(regex("^sha256:[0-9a-f]{64}$", lookup(var.image_digests, c, "")))
    ])
    error_message = "Cada componente de GKE necesita su digest sha256: producción no despliega por tag."
  }
}

variable "log_level" {
  description = "Nivel de log de los componentes."
  type        = string
  default     = "INFO"
}

variable "api_replicas" {
  description = "Réplicas de cada API (vista de despliegue: dos pods por microservicio, hipótesis por validar)."
  type        = number
  default     = 2

  validation {
    condition     = var.api_replicas >= 1
    error_message = "Cada API necesita al menos una réplica."
  }
}

variable "sync_secrets" {
  description = "Copia a GKE las contraseñas y la clave JWT desde Secret Manager. false solo para planes sin acceso a los secretos (pruebas o revisión); nunca borra los Secrets existentes."
  type        = bool
  default     = true
}

variable "secrets_revision" {
  description = "Incrementar vuelve a copiar a GKE las contraseñas y la clave JWT desde Secret Manager (tras una rotación)."
  type        = number
  default     = 1
}

variable "migration_timeout" {
  description = "Tiempo máximo para que termine cada Job de migración antes de habilitar las réplicas."
  type        = string
  default     = "15m"
}
