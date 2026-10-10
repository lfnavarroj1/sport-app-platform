variable "project_id" {
  description = "Proyecto GCP del ambiente."
  type        = string
}

variable "region" {
  description = "Región del servicio."
  type        = string
}

variable "name" {
  description = "Nombre del servicio."
  type        = string
}

variable "image" {
  description = "Imagen inmutable: <repositorio>@sha256:<digest>."
  type        = string

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.image))
    error_message = "La imagen debe referenciarse por digest (@sha256:...), nunca por tag."
  }
}

variable "service_account" {
  description = "Cuenta de servicio con la que se ejecuta."
  type        = string
}

variable "port" {
  description = "Puerto del contenedor."
  type        = number
}

variable "cpu" {
  description = "CPU por instancia, por ejemplo 1."
  type        = string
}

variable "memory" {
  description = "Memoria por instancia, por ejemplo 512Mi."
  type        = string
}

variable "min_instances" {
  description = "Instancias mínimas; 0 permite escalar a cero."
  type        = number
}

variable "max_instances" {
  description = "Tope de instancias, también como control de costo."
  type        = number
}

variable "concurrency" {
  description = "Solicitudes simultáneas por instancia."
  type        = number
}

variable "timeout_seconds" {
  description = "Tiempo máximo por solicitud."
  type        = number
}

variable "ingress" {
  description = "INGRESS_TRAFFIC_ALL, INGRESS_TRAFFIC_INTERNAL_ONLY o INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER."
  type        = string
  default     = "INGRESS_TRAFFIC_ALL"
}

variable "allow_unauthenticated" {
  description = "Concede roles/run.invoker a allUsers."
  type        = bool
}

variable "env" {
  description = "Variables de entorno no sensibles."
  type        = map(string)
  default     = {}
}

variable "secret_env" {
  description = "Variable de entorno -> id de secreto (versión latest)."
  type        = map(string)
  default     = {}
}

variable "vpc_network" {
  description = "VPC para Direct VPC egress; null si no se usa."
  type        = string
  default     = null
}

variable "vpc_subnetwork" {
  description = "Subred para Direct VPC egress; null si no se usa."
  type        = string
  default     = null
}

variable "startup_probe_path" {
  description = "Ruta HTTP de arranque; null usa la sonda TCP por defecto."
  type        = string
  default     = null
}

variable "liveness_probe_path" {
  description = "Ruta HTTP de vida; null la omite."
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Impide que Terraform elimine el servicio."
  type        = bool
}
