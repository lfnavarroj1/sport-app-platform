# --- Cuenta y credenciales (gcp.auto.tfvars, ignorado por Git) -------------

variable "project_id" {
  description = "Proyecto GCP exclusivo de este ambiente."
  type        = string
}

variable "impersonate_service_account" {
  description = "Cuenta tf-apply-* a impersonar en local; null en CI con WIF."
  type        = string
  default     = null
}

variable "alert_emails" {
  description = "Correos para alertas de Cloud Monitoring."
  type        = list(string)
  default     = []
}

variable "gke_authorized_networks" {
  description = "CIDR con acceso al endpoint IP de GKE (por ejemplo, la IP del operador)."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "artifact_registry_writers" {
  description = "Pipelines que publican imágenes (serviceAccount:... o principalSet:...)."
  type        = map(string)
  default     = {}
}

variable "labels" {
  description = "Etiquetas adicionales, por ejemplo owner o cost-center."
  type        = map(string)
  default     = {}
}

# --- Tamaño y comportamiento del ambiente (terraform.tfvars, versionado) ---

variable "region" {
  description = "Región principal."
  type        = string
}

variable "deletion_protection" {
  description = "Protege GKE, Cloud SQL y Cloud Run contra eliminación."
  type        = bool
}

variable "suspended" {
  description = "Modo suspend: detiene Cloud SQL y lleva Cloud Run a mínimo 0 (no se permite en producción)."
  type        = bool
  default     = false
}

variable "network" {
  description = "Rangos de red del ambiente."
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
  description = "Imagen por digest de web, bff-web y bff-mobile, tomada de release-manifest.yaml."
  type        = map(string)
  default     = {}
}

variable "cloud_run_public_services" {
  description = "Servicios Cloud Run invocables sin autenticación de Google."
  type        = set(string)
  default     = []
}

variable "cloud_run_env" {
  description = "Variables de entorno no sensibles por servicio."
  type        = map(map(string))
  default     = {}
}

variable "cloud_run_secret_env" {
  description = "Por servicio: variable de entorno -> secreto de app_secrets."
  type        = map(map(string))
  default     = {}
}

variable "app_secrets" {
  description = "Secretos de aplicación (solo contenedores) y cargas que pueden leerlos."
  type = map(object({
    accessors = list(string)
  }))
  default = {}
}
