terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.6"
    }
  }

  # Mismo bucket que environments/production, otro prefijo:
  #   terraform init -backend-config=backend.hcl
  backend "gcs" {
    prefix = "sportapp/delivery"
  }
}
