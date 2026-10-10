# Pruebas de plan con proveedores simulados: no requieren credenciales ni
# crean recursos. Ejecutar desde modules/gcp/platform:
#   terraform init -backend=false
#   terraform test

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
}

# random no se simula: el mock aún no admite recursos efímeros y el proveedor
# real no tiene efectos externos.

variables {
  project_id          = "sportapp-test"
  region              = "us-central1"
  environment         = "development"
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
    location        = "us-central1-a"
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
    password_version               = 1
  }

  pubsub = {
    message_retention_duration = "604800s"
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
}

run "infraestructura_sin_imagenes" {
  command = plan

  assert {
    condition     = length(module.cloud_run) == 0
    error_message = "Sin imágenes no debe crearse ningún servicio Cloud Run."
  }

  assert {
    condition     = toset(keys(module.pubsub)) == toset(["usuarios", "entrenamientos", "eventos"])
    error_message = "Solo los dominios CQRS tienen tópico y proyector."
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.db_password) == 11
    error_message = "Todas las cargas con dominio, y solo ellas, leen su contraseña."
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.db_password["training-projector"].secret_id == "db-password-entrenamientos"
    error_message = "Cada carga debe leer únicamente el secreto de su dominio."
  }
}

run "servicios_y_secretos_de_aplicacion" {
  command = plan

  variables {
    cloud_run_images = {
      bff-web = "us-central1-docker.pkg.dev/sportapp-test/sportapp/bff-web@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    }
    cloud_run_public_services = ["bff-web"]
    app_secrets = {
      jwt-signing-key = { accessors = ["users-api"] }
    }
    cloud_run_secret_env = {
      bff-web = { JWT_SIGNING_KEY = "jwt-signing-key" }
    }
  }

  assert {
    condition     = toset(keys(module.cloud_run)) == toset(["bff-web"])
    error_message = "Solo se crea el servicio con imagen."
  }

  assert {
    condition     = toset(module.app_secrets.accessor_bindings) == toset(["jwt-signing-key/bff-web", "jwt-signing-key/users-api"])
    error_message = "El secreto lo leen sus accessors y los servicios que lo montan."
  }
}

run "rechaza_imagen_por_tag" {
  command = plan

  variables {
    cloud_run_images = {
      web = "us-central1-docker.pkg.dev/sportapp-test/sportapp/web:latest"
    }
  }

  expect_failures = [var.cloud_run_images]
}

run "rechaza_secreto_no_declarado" {
  command = plan

  variables {
    cloud_run_secret_env = {
      bff-web = { JWT_SIGNING_KEY = "no-existe" }
    }
  }

  expect_failures = [var.cloud_run_secret_env]
}

run "produccion_exige_protecciones" {
  command = plan

  variables {
    environment         = "production"
    deletion_protection = false
  }

  expect_failures = [var.deletion_protection, var.cloud_sql]
}
