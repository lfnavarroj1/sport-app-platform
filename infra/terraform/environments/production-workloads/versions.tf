terraform {
  # 1.11 introduce los argumentos write-only usados para los Secrets.
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.3"
    }
    kustomization = {
      source  = "kbst/kustomization"
      version = "~> 0.9.8"
    }
  }

  # Mismo bucket que environments/production, otro prefijo:
  #   terraform init "-backend-config=backend.hcl"
  backend "gcs" {
    prefix = "sportapp/production-workloads"
  }
}
