variable "project_id" {
  description = "Proyecto GCP del ambiente."
  type        = string
}

variable "name" {
  description = "Nombre del clúster."
  type        = string
}

variable "location" {
  description = "Zona (clúster zonal) o región (clúster regional)."
  type        = string
}

variable "network" {
  description = "VPC del clúster."
  type        = string
}

variable "subnetwork" {
  description = "Subred de nodos."
  type        = string
}

variable "pods_range_name" {
  description = "Rango secundario de pods."
  type        = string
}

variable "services_range_name" {
  description = "Rango secundario de Services."
  type        = string
}

variable "release_channel" {
  description = "Canal de versiones de GKE: RAPID, REGULAR o STABLE."
  type        = string
}

variable "master_authorized_networks" {
  description = "CIDR autorizados para el endpoint IP del plano de control."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "node_pool" {
  description = "Capacidad del grupo de nodos principal."
  type = object({
    machine_type = string
    spot         = bool
    min_nodes    = number
    max_nodes    = number
    disk_size_gb = number
  })

  validation {
    condition     = var.node_pool.min_nodes >= 0 && var.node_pool.max_nodes >= var.node_pool.min_nodes && var.node_pool.max_nodes > 0
    error_message = "Se requiere 0 <= min_nodes <= max_nodes y max_nodes > 0."
  }
}

variable "suspended" {
  description = "Deja el grupo de nodos en 0 (modo suspend)."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Impide que Terraform elimine el clúster."
  type        = bool
}

variable "labels" {
  description = "Etiquetas de recursos del clúster y los nodos."
  type        = map(string)
  default     = {}
}
