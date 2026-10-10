variable "project_id" {
  description = "Proyecto GCP del ambiente."
  type        = string
}

variable "region" {
  description = "Región de las subredes."
  type        = string
}

variable "name_prefix" {
  description = "Prefijo de nombres, por ejemplo sportapp-dev."
  type        = string
}

variable "subnet_cidr" {
  description = "Rango primario de la subred de nodos GKE."
  type        = string
}

variable "pods_cidr" {
  description = "Rango secundario para pods."
  type        = string
}

variable "services_cidr" {
  description = "Rango secundario para Services de Kubernetes."
  type        = string
}

variable "serverless_cidr" {
  description = "Subred para Direct VPC egress de Cloud Run (mínimo /26)."
  type        = string

  validation {
    condition     = tonumber(split("/", var.serverless_cidr)[1]) <= 26
    error_message = "La subred de Cloud Run debe ser /26 o mayor."
  }
}

variable "private_services_prefix_length" {
  description = "Longitud del rango reservado para Private Services Access (Cloud SQL)."
  type        = number
}

variable "flow_logs_sampling" {
  description = "Muestreo de VPC Flow Logs entre 0 y 1; 0 los desactiva."
  type        = number
  default     = 0
}
