variable "project_id" {
  description = "Proyecto GCP exclusivo del ambiente."
  type        = string
}

variable "region" {
  description = "Región principal del ambiente."
  type        = string
}

variable "environment" {
  description = "development, staging o production."
  type        = string

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment debe ser development, staging o production."
  }
}

variable "labels" {
  description = "Etiquetas comunes de los recursos."
  type        = map(string)
  default     = {}
}

variable "deletion_protection" {
  description = "Protege GKE, Cloud SQL y Cloud Run contra eliminación."
  type        = bool

  validation {
    condition     = var.environment != "production" || var.deletion_protection
    error_message = "Producción exige deletion_protection = true."
  }
}

variable "suspended" {
  description = "Modo suspend: detiene Cloud SQL y lleva Cloud Run a mínimo 0. GKE se reduce escalando las cargas a 0."
  type        = bool
  default     = false

  validation {
    condition     = var.environment != "production" || !var.suspended
    error_message = "Producción no se suspende."
  }
}

variable "network" {
  description = "Rangos de red del ambiente; no deben solaparse con otros ambientes."
  type = object({
    subnet_cidr                    = string
    pods_cidr                      = string
    services_cidr                  = string
    serverless_cidr                = string
    private_services_prefix_length = number
    flow_logs_sampling             = number
  })
}

variable "gke" {
  description = "Ubicación, canal y capacidad de GKE."
  type = object({
    location        = string
    release_channel = string
    machine_type    = string
    spot            = bool
    min_nodes       = number
    max_nodes       = number
    disk_size_gb    = number
  })
}

variable "gke_authorized_networks" {
  description = "CIDR con acceso al endpoint IP del plano de control."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "gke_namespace" {
  description = "Namespace de las cargas de SportApp en GKE."
  type        = string
  default     = "sportapp"
}

variable "cloud_sql" {
  description = "Capacidad, disponibilidad y respaldos de Cloud SQL."
  type = object({
    database_version               = string
    tier                           = string
    availability_type              = string
    disk_size_gb                   = number
    disk_autoresize_limit_gb       = number
    backups_enabled                = bool
    point_in_time_recovery         = bool
    retained_backups               = number
    transaction_log_retention_days = number
    password_version               = number
  })

  validation {
    condition     = var.environment != "production" || (var.cloud_sql.availability_type == "REGIONAL" && var.cloud_sql.backups_enabled && var.cloud_sql.point_in_time_recovery)
    error_message = "Producción exige Cloud SQL REGIONAL con respaldos y recuperación a un punto en el tiempo."
  }
}

variable "pubsub" {
  description = "Parámetros de las suscripciones de proyección."
  type = object({
    message_retention_duration = string
    ack_deadline_seconds       = number
    max_delivery_attempts      = number
    minimum_backoff            = string
    maximum_backoff            = string
  })
}

variable "artifact_registry" {
  description = "Repositorio de imágenes y su limpieza."
  type = object({
    repository_id              = string
    immutable_tags             = bool
    keep_recent_versions       = number
    delete_untagged_after_days = number
    cleanup_dry_run            = bool
  })
}

variable "artifact_registry_writers" {
  description = "Pipelines que publican imágenes, por clave estable."
  type        = map(string)
  default     = {}
}

variable "cloud_run" {
  description = "Capacidad común de los servicios Cloud Run."
  type = object({
    cpu             = string
    memory          = string
    min_instances   = number
    max_instances   = number
    concurrency     = number
    timeout_seconds = number
  })
}

variable "cloud_run_images" {
  description = "Imagen por digest de web, bff-web y bff-mobile. Un servicio sin imagen no se crea."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.cloud_run_images) : contains(["web", "bff-web", "bff-mobile"], k)])
    error_message = "Las claves válidas son web, bff-web y bff-mobile."
  }

  validation {
    condition     = alltrue([for image in values(var.cloud_run_images) : can(regex("@sha256:[0-9a-f]{64}$", image))])
    error_message = "Las imágenes se referencian por digest (@sha256:...), nunca por tag."
  }
}

variable "cloud_run_public_services" {
  description = "Servicios invocables sin autenticación de Google (la app valida su propio JWT)."
  type        = set(string)
  default     = []
}

variable "cloud_run_env" {
  description = "Variables de entorno adicionales por servicio."
  type        = map(map(string))
  default     = {}
}

variable "cloud_run_secret_env" {
  description = "Por servicio: variable de entorno -> secreto de app_secrets."
  type        = map(map(string))
  default     = {}

  validation {
    condition     = alltrue(flatten([for env in values(var.cloud_run_secret_env) : [for id in values(env) : contains(keys(var.app_secrets), id)]]))
    error_message = "Cada secreto de cloud_run_secret_env debe declararse en app_secrets."
  }
}

variable "app_secrets" {
  description = "Secretos de aplicación; accessors son claves de carga (ver outputs.service_accounts)."
  type = map(object({
    accessors = list(string)
  }))
  default = {}

  validation {
    condition     = alltrue(flatten([for s in values(var.app_secrets) : [for key in s.accessors : contains(keys(local.service_accounts), key)]]))
    error_message = "Los accessors deben ser claves de carga, por ejemplo users-api, third-party o bff-web."
  }
}

variable "alert_emails" {
  description = "Correos para alertas de Cloud Monitoring."
  type        = list(string)
  default     = []
}
