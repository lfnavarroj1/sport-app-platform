variable "management_project_id" {
  description = "Proyecto de gestión: estado Terraform, cuentas de Terraform, Cloud Build y Cloud Deploy. No aloja cargas."
  type        = string
}

variable "region" {
  description = "Ubicación de los buckets de estado."
  type        = string
  default     = "us-central1"
}

variable "environments" {
  description = "Ambientes GCP. Cada uno exige un proyecto propio y ya creado con facturación."
  type = map(object({
    project_id           = string
    operators            = list(string)
    budget_amount        = optional(number, 0)
    budget_alert_amounts = optional(list(number), []) # avisos en montos absolutos; vacío = 50 %, 90 % y 100 %
    delivery             = optional(bool, false)      # identidades de Cloud Build y Cloud Deploy para este ambiente
  }))

  validation {
    condition = alltrue(flatten([
      for e in values(var.environments) : [for a in e.budget_alert_amounts : a > 0 && a <= e.budget_amount]
    ]))
    error_message = "Cada monto de budget_alert_amounts debe ser mayor que 0 y no superar budget_amount."
  }

  validation {
    condition     = alltrue([for k in keys(var.environments) : contains(["development", "staging", "production"], k)])
    error_message = "Los ambientes válidos son development, staging y production."
  }

  validation {
    condition     = length(distinct([for e in values(var.environments) : e.project_id])) == length(var.environments)
    error_message = "Cada ambiente debe usar un proyecto distinto."
  }

  # Solo personas o grupos pueden impersonar Terraform.
  validation {
    condition = alltrue(flatten([
      for e in values(var.environments) : [for m in e.operators : can(regex("^(user|group):[^@\\s]+@[^@\\s]+$", m))]
    ])) && alltrue([for e in values(var.environments) : length(e.operators) > 0])
    error_message = "operators debe listar al menos un user: o group:. Cuentas de servicio, principals de GitHub o allUsers no pueden impersonar Terraform."
  }

  validation {
    condition     = length([for e in values(var.environments) : e if e.delivery]) <= 1
    error_message = "Solo un ambiente puede tener identidades de entrega (sus nombres no llevan sufijo)."
  }
}

variable "delivery_account_ids" {
  description = "Nombres de las identidades de entrega del ambiente con delivery = true."
  type = object({
    build_backend    = string
    build_frontend   = string
    release_promoter = string
    deploy_execution = string
  })
  default = {
    build_backend    = "cloud-build-backend"
    build_frontend   = "cloud-build-frontend"
    release_promoter = "release-promoter"
    deploy_execution = "cloud-deploy-execution"
  }

  validation {
    condition     = alltrue([for id in values(var.delivery_account_ids) : can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", id)) && !startswith(id, "tf-")])
    error_message = "Cada nombre debe ser un account_id válido (6 a 30 caracteres) y no puede empezar por tf-."
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
