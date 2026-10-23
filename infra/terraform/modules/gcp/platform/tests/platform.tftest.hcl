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
  environment         = "staging"
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

  delivery_identities = {
    build_backend    = "cloud-build-backend@sportapp-mgmt-test.iam.gserviceaccount.com"
    build_frontend   = "cloud-build-frontend@sportapp-mgmt-test.iam.gserviceaccount.com"
    release_promoter = "release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com"
    deploy_execution = "cloud-deploy-execution@sportapp-mgmt-test.iam.gserviceaccount.com"
  }

  app_config = {
    registration_policies_version        = "sportapp-c108-c108plus.v1"
    health_data_consent_version          = "consentimiento-prueba.v1"
    affiliation_expected_catalog_version = "plans-2026-10-13.v1"
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
    condition     = length(google_secret_manager_secret_iam_member.db_password) == 19
    error_message = "Todas las cargas con dominio, y solo ellas, leen su contraseña."
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.db_password["training-projector"].secret_id == "db-password-entrenamientos"
    error_message = "Cada carga debe leer únicamente el secreto de su dominio."
  }

  assert {
    condition = output.pubsub["entrenamientos"] == {
      topic                    = "sportapp.entrenamientos.v1"
      projector_subscription   = "proyector-entrenamientos-v1"
      dead_letter_topic        = "sportapp.entrenamientos.proyeccion.dlq"
      dead_letter_subscription = "sportapp.entrenamientos.proyeccion.dlq.ops"
    }
    error_message = "HU010 (CMP-003): Entrenamientos usa los nombres que consumen training-management-outbox-publisher y training-management-read-projector."
  }

  assert {
    condition = output.pubsub["usuarios"] == {
      topic                    = "sportapp.usuarios.v1"
      projector_subscription   = "proyector-usuarios-v1"
      dead_letter_topic        = "sportapp.usuarios.proyeccion.dlq"
      dead_letter_subscription = "sportapp.usuarios.proyeccion.dlq.ops"
    }
    error_message = "HU001 (CMP-001): Usuarios usa los nombres que consume users-management-read-projector."
  }

  assert {
    condition = output.pubsub["eventos"] == {
      topic                    = "sportapp.eventos.v1"
      projector_subscription   = "proyector-eventos-v1"
      dead_letter_topic        = "sportapp.eventos.proyeccion.dlq"
      dead_letter_subscription = "sportapp.eventos.proyeccion.dlq.ops"
    }
    error_message = "CMP-004: Eventos usa los nombres que consume events-management-read-projector."
  }

  assert {
    condition = output.affiliation_pubsub == {
      topic                       = "sportapp.afiliacion.v1"
      free_plan_subscription      = "sportapp.afiliacion.alta-gratuita.v1"
      free_plan_dead_letter_topic = "sportapp.afiliacion.alta-gratuita.dlq"
      free_plan_dead_letter_ops   = "sportapp.afiliacion.alta-gratuita.dlq.ops"
    }
    error_message = "HU001 (ADR-024): tópico de Afiliación, alta gratuita y su DLQ con los nombres del contrato."
  }

  assert {
    condition = (
      toset(keys(google_pubsub_topic_iam_member.integration_publishers)) == toset(["affiliation-outbox", "services-outbox"]) &&
      google_pubsub_topic_iam_member.integration_publishers["affiliation-outbox"].topic == "sportapp.afiliacion.v1" &&
      google_pubsub_topic_iam_member.integration_publishers["services-outbox"].topic == "sportapp.servicios.v1" &&
      alltrue([for m in google_pubsub_topic_iam_member.integration_publishers : m.role == "roles/pubsub.publisher"])
    )
    error_message = "Solo el publicador outbox de Afiliación y el de Servicios publican, cada uno en su tópico de integración."
  }

  assert {
    condition     = output.integration_topics == { afiliacion = "sportapp.afiliacion.v1", servicios = "sportapp.servicios.v1" }
    error_message = "Afiliación y Servicios tienen tópico de integración."
  }

  # Cada dominio con base tiene una identidad de migración que solo lee su secreto.
  assert {
    condition = alltrue([
      for key, domain in {
        users-migrate       = "usuarios"
        affiliation-migrate = "afiliacion"
        services-migrate    = "servicios"
        training-migrate    = "entrenamientos"
        events-migrate      = "eventos"
      } : google_secret_manager_secret_iam_member.db_password[key].secret_id == "db-password-${domain}"
    ])
    error_message = "Los Jobs de migración tienen identidad propia por dominio y leen solo su secreto."
  }

  assert {
    condition     = toset(keys(output.gke_internal_apis)) == toset(["users-management", "affiliation-management", "training-management", "complementary-services", "events-management"])
    error_message = "Cada API que llaman los BFF tiene una IP interna reservada."
  }

  assert {
    condition = (
      alltrue([for a in google_compute_address.gke_internal_api : a.address_type == "INTERNAL"]) &&
      output.gke_internal_source_ranges == ["10.10.16.0/26"]
    )
    error_message = "Las IP de las APIs son internas y solo las alcanza la subred de Cloud Run."
  }

  assert {
    condition = (
      contains(keys(output.gke_workload_identities), "affiliation-management-free-plan-consumer") &&
      contains(keys(output.gke_workload_identities), "affiliation-management-outbox-publisher") &&
      google_secret_manager_secret_iam_member.db_password["affiliation-consumer"].secret_id == "db-password-afiliacion"
    )
    error_message = "Los workers de Afiliación tienen identidad propia y solo leen el secreto de su dominio."
  }
}

run "servicios_y_secretos_de_aplicacion" {
  command = plan

  variables {
    cloud_run_images = {
      bff-web = "us-central1-docker.pkg.dev/sportapp-test/sportapp-backend/bff-web@sha256:0000000000000000000000000000000000000000000000000000000000000000"
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

  # Los BFF arrancan solo si reciben la URL de cada API de GKE que exige su configuración.
  assert {
    condition = (
      toset(keys(output.cloud_run_env["bff-web"])) == toset([
        "APP_ENV", "USERS_MANAGEMENT_BASE_URL", "AFFILIATION_MANAGEMENT_BASE_URL", "TRAINING_MANAGEMENT_BASE_URL",
        "COMPLEMENTARY_SERVICES_BASE_URL", "EVENTS_MANAGEMENT_BASE_URL", "CORS_ALLOWED_ORIGINS",
      ]) &&
      toset(keys(output.cloud_run_env["bff-mobile"])) == toset([
        "APP_ENV", "USERS_MANAGEMENT_BASE_URL", "AFFILIATION_MANAGEMENT_BASE_URL", "TRAINING_MANAGEMENT_BASE_URL", "EVENTS_MANAGEMENT_BASE_URL",
      ])
    )
    error_message = "bff-web y bff-mobile reciben las URL internas de las APIs que exige su configuración."
  }

  assert {
    condition = (
      output.cloud_run_env["bff-web"].CORS_ALLOWED_ORIGINS == "https://web-123456789012.us-central1.run.app" &&
      output.cloud_run_env["web"].BFF_WEB_BASE_URL == "https://bff-web-123456789012.us-central1.run.app" &&
      output.cloud_run_env["web"].REGISTRATION_POLICIES_VERSION == "sportapp-c108-c108plus.v1" &&
      output.cloud_run_env["web"].HEALTH_DATA_CONSENT_VERSION == "consentimiento-prueba.v1"
    )
    error_message = "web y bff-web se referencian por sus URL deterministas y la web recibe las versiones del ambiente."
  }
}

run "rechaza_imagen_por_tag" {
  command = plan

  variables {
    cloud_run_images = {
      web = "us-central1-docker.pkg.dev/sportapp-test/sportapp-frontend/web:latest"
    }
  }

  expect_failures = [var.cloud_run_images]
}

run "rechaza_imagen_externa" {
  command = plan

  variables {
    cloud_run_images = {
      bff-web = "docker.io/library/nginx@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    }
  }

  expect_failures = [var.cloud_run_images]
}

run "rechaza_imagen_del_otro_componente" {
  command = plan

  variables {
    cloud_run_images = {
      web = "us-central1-docker.pkg.dev/sportapp-test/sportapp-backend/web@sha256:0000000000000000000000000000000000000000000000000000000000000000"
    }
  }

  expect_failures = [var.cloud_run_images]
}

run "rechaza_identidad_terraform_como_entrega" {
  command = plan

  variables {
    delivery_identities = {
      build_backend    = "cloud-build-backend@sportapp-mgmt-test.iam.gserviceaccount.com"
      build_frontend   = "cloud-build-frontend@sportapp-mgmt-test.iam.gserviceaccount.com"
      release_promoter = "release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com"
      deploy_execution = "tf-apply-production@sportapp-mgmt-test.iam.gserviceaccount.com"
    }
  }

  expect_failures = [var.delivery_identities]
}

# Separación de Artifact Registry y permisos cruzados de Cloud Deploy.
run "entrega_separada" {
  command = plan

  variables {
    cloud_run_images = {
      web        = "us-central1-docker.pkg.dev/sportapp-test/sportapp-frontend/web@sha256:1111111111111111111111111111111111111111111111111111111111111111"
      bff-web    = "us-central1-docker.pkg.dev/sportapp-test/sportapp-backend/bff-web@sha256:2222222222222222222222222222222222222222222222222222222222222222"
      bff-mobile = "us-central1-docker.pkg.dev/sportapp-test/sportapp-backend/bff-mobile@sha256:3333333333333333333333333333333333333333333333333333333333333333"
    }
  }

  assert {
    condition = (
      output.artifact_registry_urls == {
        backend  = "us-central1-docker.pkg.dev/sportapp-test/sportapp-backend"
        frontend = "us-central1-docker.pkg.dev/sportapp-test/sportapp-frontend"
      }
    )
    error_message = "Hay un repositorio de Artifact Registry por componente."
  }

  # Cada cuenta de Cloud Build escribe solo en su repositorio; nadie más escribe.
  assert {
    condition = (
      local.artifact_repository_writers.backend == { cloud-build-backend = "serviceAccount:cloud-build-backend@sportapp-mgmt-test.iam.gserviceaccount.com" } &&
      local.artifact_repository_writers.frontend == { cloud-build-frontend = "serviceAccount:cloud-build-frontend@sportapp-mgmt-test.iam.gserviceaccount.com" }
    )
    error_message = "cloud-build-backend solo escribe en sportapp-backend y cloud-build-frontend solo en sportapp-frontend."
  }

  # Ejecución y promoción solo leen; las cuentas de build no leen el repositorio ajeno.
  assert {
    condition = alltrue([
      for key, readers in local.artifact_repository_readers : (
        readers["deploy-execution"] == "serviceAccount:cloud-deploy-execution@sportapp-mgmt-test.iam.gserviceaccount.com" &&
        readers["release-promoter"] == "serviceAccount:release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com" &&
        !anytrue([for k in keys(readers) : strcontains(k, "cloud-build")])
      )
    ])
    error_message = "cloud-deploy-execution y release-promoter solo leen ambos repositorios."
  }

  assert {
    condition = (
      google_project_iam_member.deploy_execution_cluster.role == "roles/container.clusterViewer" &&
      toset(keys(google_service_account_iam_member.deploy_execution_act_as)) == toset(["web", "bff-web", "bff-mobile"]) &&
      alltrue([for b in google_service_account_iam_member.deploy_execution_act_as : b.role == "roles/iam.serviceAccountUser" && b.member == "serviceAccount:cloud-deploy-execution@sportapp-mgmt-test.iam.gserviceaccount.com"])
    )
    error_message = "cloud-deploy-execution solo obtiene credenciales del clúster y adjunta las cuentas de los servicios de Cloud Run."
  }

  assert {
    condition = (
      toset(keys(output.cloud_run_deploy_config)) == toset(["web", "bff-web", "bff-mobile"]) &&
      output.cloud_run_deploy_config["web"].repository == "frontend" &&
      output.cloud_run_deploy_config["bff-web"].repository == "backend" &&
      keys(output.cloud_run_deploy_config["bff-web"].env) == keys(output.cloud_run_env["bff-web"])
    )
    error_message = "Cloud Deploy recibe la misma configuración de Cloud Run que administra Terraform."
  }

  assert {
    condition     = length(google_binary_authorization_policy.this) == 0
    error_message = "Binary Authorization está deshabilitada por defecto."
  }
}

run "binary_authorization_exige_attestors" {
  command = plan

  variables {
    binary_authorization = { enabled = true }
  }

  expect_failures = [var.binary_authorization]
}

run "binary_authorization_habilitada" {
  command = plan

  variables {
    binary_authorization = { enabled = true, attestors = ["projects/sportapp-test/attestors/cloud-build"] }
  }

  assert {
    condition = (
      google_binary_authorization_policy.this[0].default_admission_rule[0].evaluation_mode == "REQUIRE_ATTESTATION" &&
      google_binary_authorization_policy.this[0].default_admission_rule[0].enforcement_mode == "ENFORCED_BLOCK_AND_AUDIT_LOG"
    )
    error_message = "Con Binary Authorization solo se admiten imágenes con attestation."
  }
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

run "produccion_suspendida" {
  command = plan

  variables {
    environment         = "production"
    deletion_protection = true
    suspended           = true
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
      password_version               = 1
    }
  }
}

run "produccion_destruccion_sin_confirmacion_valida" {
  command = plan

  variables {
    environment          = "production"
    deletion_protection  = false
    destroy_confirmation = "otro-proyecto"
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
      password_version               = 1
    }
  }

  expect_failures = [var.deletion_protection]
}

run "produccion_destruccion_confirmada" {
  command = plan

  variables {
    environment          = "production"
    deletion_protection  = false
    destroy_confirmation = "sportapp-test"
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
      password_version               = 1
    }
  }
}
