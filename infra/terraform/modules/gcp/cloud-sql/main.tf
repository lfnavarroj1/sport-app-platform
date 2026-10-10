# Instancia PostgreSQL privada con bases lógicas y un usuario por dominio.
#
# Las contraseñas se generan como valores efímeros y se envían con argumentos
# write-only: llegan a Cloud SQL y a Secret Manager, pero nunca al estado.
# Para rotarlas se incrementa password_version.

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.6"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.7"
    }
  }
}

# Un nombre de instancia no puede reutilizarse durante días tras borrarla;
# el sufijo permite recrear desarrollo sin esperar.
resource "random_id" "suffix" {
  byte_length = 2
}

resource "google_sql_database_instance" "this" {
  project             = var.project_id
  name                = "${var.name_prefix}-pg-${random_id.suffix.hex}"
  region              = var.region
  database_version    = var.database_version
  deletion_protection = var.deletion_protection

  settings {
    tier                        = var.tier
    activation_policy           = var.stopped ? "NEVER" : "ALWAYS"
    edition                     = "ENTERPRISE"
    availability_type           = var.availability_type
    disk_type                   = "PD_SSD"
    disk_size                   = var.disk_size_gb
    disk_autoresize             = true
    disk_autoresize_limit       = var.disk_autoresize_limit_gb
    deletion_protection_enabled = var.deletion_protection
    retain_backups_on_delete    = var.deletion_protection
    user_labels                 = var.labels

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = var.private_network
      ssl_mode                                      = "ENCRYPTED_ONLY"
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled                        = var.backups.enabled
      start_time                     = "06:00"
      point_in_time_recovery_enabled = var.backups.point_in_time_recovery
      transaction_log_retention_days = var.backups.transaction_log_retention_days

      backup_retention_settings {
        retained_backups = var.backups.retained_backups
        retention_unit   = "COUNT"
      }
    }

    maintenance_window {
      day          = 7
      hour         = 7
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
      record_client_address   = false
    }
  }
}

# ABANDON: al destruir el ambiente la instancia se elimina con sus bases; así se
# evita el fallo de PostgreSQL al borrar bases con conexiones o roles con objetos.
resource "google_sql_database" "this" {
  for_each = var.databases

  project         = var.project_id
  instance        = google_sql_database_instance.this.name
  name            = each.value
  deletion_policy = "ABANDON"
}

ephemeral "random_password" "users" {
  for_each = var.users

  length           = 32
  special          = true
  override_special = "-_"
}

resource "google_sql_user" "this" {
  for_each = var.users

  project             = var.project_id
  instance            = google_sql_database_instance.this.name
  name                = each.value
  password_wo         = ephemeral.random_password.users[each.key].result
  password_wo_version = var.password_version
  deletion_policy     = "ABANDON"
}

resource "google_secret_manager_secret" "passwords" {
  for_each = var.users

  project   = var.project_id
  secret_id = "db-password-${each.value}"
  labels    = var.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "passwords" {
  for_each = var.users

  secret                 = google_secret_manager_secret.passwords[each.key].id
  secret_data_wo         = ephemeral.random_password.users[each.key].result
  secret_data_wo_version = var.password_version

  # La versión del secreto se publica cuando el usuario ya tiene la contraseña.
  depends_on = [google_sql_user.this]
}
