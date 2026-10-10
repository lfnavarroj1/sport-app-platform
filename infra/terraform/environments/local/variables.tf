variable "kube_context" {
  description = "Contexto de kubectl. Solo se admite el Kubernetes de Docker Desktop."
  type        = string
  default     = "docker-desktop"

  validation {
    condition     = var.kube_context == "docker-desktop"
    error_message = "El ambiente local solo se aplica en el contexto docker-desktop."
  }
}

variable "kubeconfig_path" {
  description = "Archivo kubeconfig."
  type        = string
  default     = "~/.kube/config"
}

variable "deploy_backend" {
  description = "Despliega los componentes del backend; false deja solo PostgreSQL y Pub/Sub."
  type        = bool
  default     = true
}

variable "backend_path" {
  description = "Repositorio backend, relativo a esta carpeta (clon hermano o components/backend)."
  type        = string
  default     = "../../../../../backend"
}

variable "backend_image_tag" {
  description = "Tag de las imágenes sportapp/* construidas con scripts/task.py build."
  type        = string
  default     = "local"
}

variable "backend_image_tags" {
  description = "Tag por componente, cuando solo se reconstruyó uno (por ejemplo users-management)."
  type        = map(string)
  default     = {}
}

variable "log_level" {
  description = "LOG_LEVEL de todos los componentes."
  type        = string
  default     = "INFO"
}

variable "registration_policies_version" {
  description = "Versión de políticas aceptadas al registrarse (users-management)."
  type        = string
  default     = "local-dev"
}

variable "password_revision" {
  description = "Incrementar regenera las contraseñas; exige recrear PostgreSQL (ver README)."
  type        = number
  default     = 1
}

variable "wait_for_rollout" {
  description = "Espera a que cada Deployment y StatefulSet quede listo durante el apply."
  type        = bool
  default     = true
}
