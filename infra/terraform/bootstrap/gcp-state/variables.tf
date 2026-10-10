variable "management_project_id" {
  description = "Proyecto de gestión: estado Terraform, WIF y cuentas de despliegue. No aloja cargas."
  type        = string
}

variable "region" {
  description = "Ubicación de los buckets de estado."
  type        = string
  default     = "us-central1"
}

variable "github_repository" {
  description = "Repositorio autorizado a obtener credenciales por OIDC (propietario/nombre)."
  type        = string
  default     = "lfnavarroj1/sport-app-platform"
}

variable "component_repositories" {
  description = "Repositorios de componentes que publican imágenes con la cuenta ci-delivery-<ambiente>."
  type        = list(string)
  default     = ["lfnavarroj1/sport-app-backend", "lfnavarroj1/sport-app-frontend"]
}

variable "environments" {
  description = "Ambientes GCP. Cada uno exige un proyecto propio y ya creado con facturación."
  type = map(object({
    project_id         = string
    operators          = optional(list(string), [])
    budget_amount      = optional(number, 0)
    component_delivery = optional(bool, false) # crea ci-delivery-<ambiente> para backend/frontend
  }))

  validation {
    condition     = alltrue([for k in keys(var.environments) : contains(["development", "staging", "production"], k)])
    error_message = "Los ambientes válidos son development, staging y production."
  }

  validation {
    condition     = length(distinct([for e in values(var.environments) : e.project_id])) == length(var.environments)
    error_message = "Cada ambiente debe usar un proyecto distinto."
  }
}

variable "billing_account" {
  description = "Cuenta de facturación (XXXXXX-XXXXXX-XXXXXX) para presupuestos; null los omite."
  type        = string
  default     = null
}

variable "budget_currency" {
  description = "Moneda de los presupuestos; debe coincidir con la de la cuenta de facturación."
  type        = string
  default     = "USD"
}

variable "state_versions_to_keep" {
  description = "Versiones anteriores del estado que conserva cada bucket."
  type        = number
  default     = 30
}
