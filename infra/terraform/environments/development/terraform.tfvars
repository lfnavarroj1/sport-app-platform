# Valores NO sensibles de desarrollo. Se versionan y se revisan en PR.
# La cuenta, credenciales y correos van en gcp.auto.tfvars (ignorado por Git).
#
# Desarrollo es desechable: sin protección contra borrado, nodos spot, una
# zona y Cloud SQL zonal. Las capacidades son iniciales y se ajustan con
# los experimentos de carga (ADR-011).

region              = "us-central1"
deletion_protection = false

network = {
  subnet_cidr                    = "10.10.0.0/20"
  serverless_cidr                = "10.10.16.0/26"
  pods_cidr                      = "10.11.0.0/17"
  services_cidr                  = "10.11.128.0/20"
  private_services_prefix_length = 20
  flow_logs_sampling             = 0
}

gke = {
  location        = "us-central1-a" # zonal: un solo plano de control y menor costo
  release_channel = "REGULAR"
  machine_type    = "e2-standard-2"
  spot            = true
  min_nodes       = 0
  max_nodes       = 3
  disk_size_gb    = 50
}

cloud_sql = {
  database_version               = "POSTGRES_17"
  tier                           = "db-custom-1-3840"
  availability_type              = "ZONAL"
  disk_size_gb                   = 10
  disk_autoresize_limit_gb       = 50
  backups_enabled                = true
  point_in_time_recovery         = false
  retained_backups               = 3
  transaction_log_retention_days = 1
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
  keep_recent_versions       = 10
  delete_untagged_after_days = 7
  cleanup_dry_run            = false
}

cloud_run = {
  cpu             = "1"
  memory          = "512Mi"
  min_instances   = 0
  max_instances   = 3
  concurrency     = 80
  timeout_seconds = 30
}

# Se completa desde release-manifest.yaml. Un servicio sin imagen no se crea,
# lo que permite levantar la infraestructura antes del primer artefacto.
# Ejemplo:
#   bff-web = "us-central1-docker.pkg.dev/<proyecto>/sportapp/bff-web@sha256:<digest>"
cloud_run_images = {}

# Provisional hasta decidir la capa de borde (API Gateway / balanceador).
cloud_run_public_services = ["web", "bff-web", "bff-mobile"]

# USERS_MANAGEMENT_BASE_URL apunta al Service interno de GKE cuando exista.
cloud_run_env = {
  bff-web    = { LOG_LEVEL = "DEBUG" }
  bff-mobile = { LOG_LEVEL = "DEBUG" }
}

# Solo contenedores; los valores se cargan con gcloud (ver README).
# Ejemplo cuando ADR-009 y la integración con Strava estén definidos:
#   app_secrets = {
#     jwt-signing-key      = { accessors = ["bff-web", "bff-mobile", "users-api"] }
#     strava-client-secret = { accessors = ["third-party"] }
#   }
#   cloud_run_secret_env = { bff-web = { JWT_SIGNING_KEY = "jwt-signing-key" } }
app_secrets          = {}
cloud_run_secret_env = {}
