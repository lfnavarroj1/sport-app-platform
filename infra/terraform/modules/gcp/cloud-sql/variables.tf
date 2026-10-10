variable "project_id" {
  description = "Proyecto GCP del ambiente."
  type        = string
}

variable "region" {
  description = "Región de la instancia."
  type        = string
}

variable "name_prefix" {
  description = "Prefijo del nombre de la instancia."
  type        = string
}

variable "private_network" {
  description = "VPC con Private Services Access."
  type        = string
}

variable "database_version" {
  description = "Versión de PostgreSQL, por ejemplo POSTGRES_17."
  type        = string
}

variable "tier" {
  description = "Tipo de máquina, por ejemplo db-custom-1-3840."
  type        = string
}

variable "availability_type" {
  description = "ZONAL o REGIONAL (alta disponibilidad)."
  type        = string

  validation {
    condition     = contains(["ZONAL", "REGIONAL"], var.availability_type)
    error_message = "availability_type debe ser ZONAL o REGIONAL."
  }
}

variable "disk_size_gb" {
  description = "Disco inicial en GB."
  type        = number
}

variable "disk_autoresize_limit_gb" {
  description = "Tope de crecimiento automático del disco en GB."
  type        = number
}

variable "backups" {
  description = "Respaldos automáticos y recuperación a un punto en el tiempo."
  type = object({
    enabled                        = bool
    point_in_time_recovery         = bool
    retained_backups               = number
    transaction_log_retention_days = number
  })

  validation {
    condition     = !var.backups.point_in_time_recovery || var.backups.enabled
    error_message = "La recuperación a un punto en el tiempo requiere respaldos habilitados."
  }
}

variable "databases" {
  description = "Bases lógicas a crear."
  type        = set(string)
}

variable "users" {
  description = "Usuarios PostgreSQL; cada uno recibe un secreto db-password-<usuario>."
  type        = set(string)
}

variable "password_version" {
  description = "Incrementar para rotar todas las contraseñas de base de datos."
  type        = number
}

variable "stopped" {
  description = "Detiene la instancia (se sigue cobrando el almacenamiento)."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Impide eliminar la instancia y conserva respaldos si se elimina."
  type        = bool
}

variable "labels" {
  description = "Etiquetas de la instancia y los secretos."
  type        = map(string)
  default     = {}
}
