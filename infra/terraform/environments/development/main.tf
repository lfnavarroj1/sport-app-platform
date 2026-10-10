locals {
  environment = "development"

  labels = merge(var.labels, {
    app         = "sportapp"
    environment = local.environment
    managed-by  = "terraform"
  })
}

module "platform" {
  source = "../../modules/gcp/platform"

  project_id                = var.project_id
  region                    = var.region
  environment               = local.environment
  labels                    = local.labels
  deletion_protection       = var.deletion_protection
  suspended                 = var.suspended
  network                   = var.network
  gke                       = var.gke
  gke_authorized_networks   = var.gke_authorized_networks
  cloud_sql                 = var.cloud_sql
  pubsub                    = var.pubsub
  artifact_registry         = var.artifact_registry
  artifact_registry_writers = var.artifact_registry_writers
  cloud_run                 = var.cloud_run
  cloud_run_images          = var.cloud_run_images
  cloud_run_public_services = var.cloud_run_public_services
  cloud_run_env             = var.cloud_run_env
  cloud_run_secret_env      = var.cloud_run_secret_env
  app_secrets               = var.app_secrets
  alert_emails              = var.alert_emails
}
