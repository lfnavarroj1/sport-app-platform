# Valores NO sensibles de producción. Se versionan y se revisan en PR.
# La cuenta, credenciales y correos van en gcp.auto.tfvars (ignorado por Git).
#
# Producción: protección contra borrado, GKE regional (tres zonas) sin spot y
# Cloud SQL regional con PITR. El módulo rechaza un plan de producción que
# desactive estas garantías. Las capacidades son iniciales (ADR-011).

region              = "us-central1"
deletion_protection = true

# Rangos distintos de desarrollo para permitir conectividad futura entre VPC.
network = {
  subnet_cidr                    = "10.20.0.0/20"
  serverless_cidr                = "10.20.16.0/26"
  pods_cidr                      = "10.21.0.0/17"
  services_cidr                  = "10.21.128.0/20"
  private_services_prefix_length = 20
  flow_logs_sampling             = 0.5
}

gke = {
  location        = "us-central1" # regional: plano de control y nodos en tres zonas
  release_channel = "STABLE"
  machine_type    = "e2-standard-4"
  spot            = false
  min_nodes       = 3 # total del grupo: uno por zona
  max_nodes       = 9
  disk_size_gb    = 100
}

cloud_sql = {
  database_version               = "POSTGRES_17"
  tier                           = "db-custom-2-7680"
  availability_type              = "REGIONAL"
  disk_size_gb                   = 20
  disk_autoresize_limit_gb       = 200
  backups_enabled                = true
  point_in_time_recovery         = true
  retained_backups               = 14
  transaction_log_retention_days = 7
  password_version               = 1 # incrementar para rotar contraseñas
}

pubsub = {
  message_retention_duration = "604800s" # 7 días
  ack_deadline_seconds       = 60
  max_delivery_attempts      = 10
  minimum_backoff            = "10s"
  maximum_backoff            = "600s"
}

artifact_registry = {
  repository_id              = "sportapp"
  immutable_tags             = true
  keep_recent_versions       = 30
  delete_untagged_after_days = 30
  cleanup_dry_run            = false
}

cloud_run = {
  cpu             = "1"
  memory          = "512Mi"
  min_instances   = 1 # evita arranque en frío
  max_instances   = 10
  concurrency     = 80
  timeout_seconds = 30
}

# Mismos digests aprobados en staging, tomados de release-manifest.yaml.
cloud_run_images = {}

# Provisional hasta decidir la capa de borde (API Gateway / balanceador).
cloud_run_public_services = ["web", "bff-web", "bff-mobile"]

cloud_run_env = {
  bff-web    = { LOG_LEVEL = "INFO" }
  bff-mobile = { LOG_LEVEL = "INFO" }
}

# Solo contenedores; los valores se cargan con gcloud (ver README).
app_secrets          = {}
cloud_run_secret_env = {}
