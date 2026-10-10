terraform {
  # 1.11 introduce los argumentos write-only usados para las contraseñas.
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.6"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # El bucket (y la impersonación local, si aplica) se pasan con
  #   terraform init -backend-config=backend.hcl
  backend "gcs" {
    prefix = "sportapp/production"
  }
}
