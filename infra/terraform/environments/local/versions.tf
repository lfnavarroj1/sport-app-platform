terraform {
  # 1.11 introduce los argumentos write-only usados para las contraseñas.
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.3"
    }
    kustomization = {
      source  = "kbst/kustomization"
      version = "~> 0.9.8"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1"
    }
  }

  # Estado local (terraform.tfstate, ignorado por Git): el ambiente es
  # desechable y las contraseñas no se guardan en él (write-only).
}
