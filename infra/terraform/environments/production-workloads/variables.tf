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
  description = "Cuenta tf-apply-production (o tf-plan-production para revisar) que el operador impersona desde su estación."
  type        = string

  validation {
    condition     = can(regex("^tf-(apply|plan)-production@[a-z][a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", var.impersonate_service_account))
    error_message = "Esta raíz se ejecuta impersonando tf-apply-production o tf-plan-production."
  }
}

variable "state_bucket" {
  description = "Bucket de estado creado por el bootstrap; de él se leen las salidas de environments/production."
  type        = string
}

variable "backend_path" {
  description = "Carpeta del repositorio backend, relativa a esta carpeta (submódulo por defecto); de ella se toman los Services."
  type        = string
  default     = "../../../../components/backend"
}

variable "log_level" {
  description = "Nivel de log de los componentes (sportapp-runtime)."
  type        = string
  default     = "INFO"
}

variable "sync_secrets" {
  description = "Copia a GKE las contraseñas y la clave JWT desde Secret Manager. false solo para planes sin acceso a los secretos (pruebas o revisión con tf-plan); nunca borra los Secrets existentes."
  type        = bool
  default     = true
}

variable "secrets_revision" {
  description = "Incrementar vuelve a copiar a GKE las contraseñas y la clave JWT desde Secret Manager (tras una rotación)."
  type        = number
  default     = 1
}
