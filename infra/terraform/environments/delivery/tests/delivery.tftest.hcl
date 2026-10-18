# Pruebas de plan sin credenciales: google simulado y estado de producción
# reemplazado. Ejecutar:
#   terraform init -backend=false
#   terraform test

mock_provider "google" {}

override_data {
  target = data.terraform_remote_state.production
  values = {
    outputs = {
      artifact_registry_urls = {
        backend  = "us-central1-docker.pkg.dev/sportapp-prod-test/sportapp-backend"
        frontend = "us-central1-docker.pkg.dev/sportapp-prod-test/sportapp-frontend"
      }
      gke = { name = "sportapp-prod-gke", location = "us-central1", dns_endpoint = "gke-0000.us-central1.gke.goog", namespace = "sportapp", cluster_id = "projects/sportapp-prod-test/locations/us-central1/clusters/sportapp-prod-gke" }
      delivery_identities = {
        build_backend    = "cloud-build-backend@sportapp-mgmt-test.iam.gserviceaccount.com"
        build_frontend   = "cloud-build-frontend@sportapp-mgmt-test.iam.gserviceaccount.com"
        release_promoter = "release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com"
        deploy_execution = "cloud-deploy-execution@sportapp-mgmt-test.iam.gserviceaccount.com"
      }
      cloud_run_deploy_config = {
        bff-web = {
          name            = "bff-web", location = "projects/sportapp-prod-test/locations/us-central1", repository = "backend"
          service_account = "run-bff-web@sportapp-prod-test.iam.gserviceaccount.com", port = 8000, cpu = "1", memory = "512Mi"
          min_instances   = 1, max_instances = 10, concurrency = 80, timeout_seconds = 30
          vpc_network     = "sportapp-prod-vpc", vpc_subnetwork = "sportapp-prod-serverless"
          env = {
            APP_ENV                         = "production", LOG_LEVEL = "INFO", CORS_ALLOWED_ORIGINS = "https://web-1.us-central1.run.app"
            USERS_MANAGEMENT_BASE_URL       = "http://10.10.0.10", AFFILIATION_MANAGEMENT_BASE_URL = "http://10.10.0.11", TRAINING_MANAGEMENT_BASE_URL = "http://10.10.0.12"
            COMPLEMENTARY_SERVICES_BASE_URL = "http://10.10.0.13", EVENTS_MANAGEMENT_BASE_URL = "http://10.10.0.14"
          }
          secret_env = {}
          uri        = "https://bff-web-1.us-central1.run.app"
        }
        bff-mobile = {
          name            = "bff-mobile", location = "projects/sportapp-prod-test/locations/us-central1", repository = "backend"
          service_account = "run-bff-mobile@sportapp-prod-test.iam.gserviceaccount.com", port = 8000, cpu = "1", memory = "512Mi"
          min_instances   = 1, max_instances = 10, concurrency = 80, timeout_seconds = 30
          vpc_network     = "sportapp-prod-vpc", vpc_subnetwork = "sportapp-prod-serverless"
          env = {
            APP_ENV                      = "production", LOG_LEVEL = "INFO", USERS_MANAGEMENT_BASE_URL = "http://10.10.0.10", AFFILIATION_MANAGEMENT_BASE_URL = "http://10.10.0.11"
            TRAINING_MANAGEMENT_BASE_URL = "http://10.10.0.12", EVENTS_MANAGEMENT_BASE_URL = "http://10.10.0.14"
          }
          secret_env = {}
          uri        = "https://bff-mobile-1.us-central1.run.app"
        }
        web = {
          name            = "web", location = "projects/sportapp-prod-test/locations/us-central1", repository = "frontend"
          service_account = "run-web@sportapp-prod-test.iam.gserviceaccount.com", port = 8080, cpu = "1", memory = "512Mi"
          min_instances   = 1, max_instances = 10, concurrency = 80, timeout_seconds = 30
          vpc_network     = null, vpc_subnetwork = null
          env = {
            APP_ENV                       = "production", BFF_WEB_BASE_URL = "https://bff-web-1.us-central1.run.app"
            REGISTRATION_POLICIES_VERSION = "sportapp-c108-c108plus.v1", HEALTH_DATA_CONSENT_VERSION = "consentimiento-prueba.v1"
          }
          secret_env = {}
          uri        = "https://web-1.us-central1.run.app"
        }
      }
    }
  }
}

variables {
  management_project_id       = "sportapp-mgmt-test"
  impersonate_service_account = "tf-apply-production@sportapp-mgmt-test.iam.gserviceaccount.com"
  state_bucket                = "sportapp-mgmt-test-tfstate-production"
  delivery_identities = {
    build_backend    = "cloud-build-backend@sportapp-mgmt-test.iam.gserviceaccount.com"
    build_frontend   = "cloud-build-frontend@sportapp-mgmt-test.iam.gserviceaccount.com"
    release_promoter = "release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com"
    deploy_execution = "cloud-deploy-execution@sportapp-mgmt-test.iam.gserviceaccount.com"
  }
  approvers          = ["user:operador@example.com", "group:aprobadores@example.com"]
  deploy_tools_image = "gcr.io/google.com/cloudsdktool/google-cloud-cli:588.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111"
}

# Primer apply: conexión pendiente de autorizar, sin repositorios ni triggers.
run "antes_de_autorizar_la_github_app" {
  command = plan

  assert {
    condition     = length(google_cloudbuildv2_repository.this) == 0 && length(google_cloudbuild_trigger.release) == 0 && length(google_cloudbuild_trigger.promote) == 0
    error_message = "Sin la GitHub App autorizada no se crean repositorios ni triggers."
  }

  assert {
    condition     = google_cloudbuildv2_connection.github.location == "us-central1"
    error_message = "La conexión se crea en GCP (región del plano de entrega)."
  }
}

run "evidencia_separada_y_privada" {
  command = plan

  assert {
    condition = alltrue([
      for b in google_storage_bucket.evidence : b.public_access_prevention == "enforced" && b.uniform_bucket_level_access && b.versioning[0].enabled
    ])
    error_message = "La evidencia es privada, uniforme y versionada."
  }

  assert {
    condition = (
      google_storage_bucket_iam_member.evidence_writer["backend"].member == "serviceAccount:cloud-build-backend@sportapp-mgmt-test.iam.gserviceaccount.com" &&
      google_storage_bucket_iam_member.evidence_writer["frontend"].member == "serviceAccount:cloud-build-frontend@sportapp-mgmt-test.iam.gserviceaccount.com" &&
      google_storage_bucket_iam_member.evidence_writer["backend"].bucket == "sportapp-mgmt-test-delivery-evidence-backend" &&
      google_storage_bucket_iam_member.evidence_writer["frontend"].bucket == "sportapp-mgmt-test-delivery-evidence-frontend" &&
      alltrue([for w in google_storage_bucket_iam_member.evidence_writer : w.role == "roles/storage.objectCreator"])
    )
    error_message = "Cada build solo crea evidencia en su bucket: no sobrescribe ni escribe la del otro componente."
  }

  assert {
    condition = alltrue([
      for r in google_storage_bucket_iam_member.evidence_reader : r.role == "roles/storage.objectViewer" && r.member == "serviceAccount:release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com"
    ])
    error_message = "release-promoter solo lee la evidencia."
  }
}

run "targets_con_aprobacion" {
  command = plan

  assert {
    condition = (
      alltrue([for t in google_clouddeploy_target.gke : t.require_approval]) &&
      alltrue([for t in google_clouddeploy_target.run : t.require_approval]) &&
      length(google_clouddeploy_target.gke) == 2 && length(google_clouddeploy_target.run) == 3
    )
    error_message = "Todos los targets productivos exigen aprobación humana."
  }

  assert {
    condition = alltrue([
      for t in concat(values(google_clouddeploy_target.gke), values(google_clouddeploy_target.run)) :
      alltrue([for c in t.execution_configs : c.service_account == "cloud-deploy-execution@sportapp-mgmt-test.iam.gserviceaccount.com"])
    ])
    error_message = "Todos los targets se ejecutan con cloud-deploy-execution."
  }

  assert {
    condition = (
      google_clouddeploy_target.gke["production-gke"].gke[0].cluster == "projects/sportapp-prod-test/locations/us-central1/clusters/sportapp-prod-gke" &&
      google_clouddeploy_target.gke["production-gke"].gke[0].dns_endpoint &&
      google_clouddeploy_target.run["web"].run[0].location == "projects/sportapp-prod-test/locations/us-central1"
    )
    error_message = "Los targets apuntan al clúster y a la región de producción."
  }

  # Backend: primero las migraciones, después los Deployments.
  assert {
    condition = (
      jsonencode([for s in google_clouddeploy_delivery_pipeline.this["backend-gke"].serial_pipeline[0].stages : s.target_id]) == jsonencode(["production-gke-migrations", "production-gke"]) &&
      jsonencode([for s in google_clouddeploy_delivery_pipeline.this["backend-gke"].serial_pipeline[0].stages : s.profiles]) == jsonencode([["migrations"], ["workloads"]]) &&
      alltrue([for s in google_clouddeploy_delivery_pipeline.this["backend-gke"].serial_pipeline[0].stages : s.strategy[0].standard[0].verify])
    )
    error_message = "backend-gke ejecuta y verifica las migraciones antes de habilitar la etapa de Deployments."
  }

  assert {
    condition     = toset(keys(google_clouddeploy_delivery_pipeline.this)) == toset(["backend-gke", "bff-web", "bff-mobile", "frontend-web"])
    error_message = "Existen exactamente los pipelines backend-gke, bff-web, bff-mobile y frontend-web."
  }

  # Un rollout de Cloud Run no cambia la configuración que administra Terraform.
  assert {
    condition = (
      google_clouddeploy_target.run["bff-web"].deploy_parameters["env_USERS_MANAGEMENT_BASE_URL"] == "http://10.10.0.10" &&
      google_clouddeploy_target.run["bff-web"].deploy_parameters["service_account"] == "run-bff-web@sportapp-prod-test.iam.gserviceaccount.com" &&
      jsondecode(google_clouddeploy_target.run["bff-web"].deploy_parameters["network_interfaces"]) == [{ network = "sportapp-prod-vpc", subnetwork = "sportapp-prod-serverless" }] &&
      !contains(keys(google_clouddeploy_target.run["web"].deploy_parameters), "network_interfaces")
    )
    error_message = "Los parámetros de los targets de Cloud Run repiten la configuración de Terraform."
  }
}

run "aprobadores_y_promotor" {
  command = plan

  assert {
    condition = alltrue([
      for m in google_clouddeploy_delivery_pipeline_iam_member.approver : contains(["user:operador@example.com", "group:aprobadores@example.com"], m.member) && m.role == "roles/clouddeploy.approver"
    ]) && length(google_clouddeploy_delivery_pipeline_iam_member.approver) == 8
    error_message = "Solo las personas o grupos declarados aprueban, en los cuatro pipelines."
  }

  assert {
    condition = alltrue([
      for m in google_clouddeploy_delivery_pipeline_iam_member.releaser : m.role == "roles/clouddeploy.releaser" && m.member == "serviceAccount:release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com"
    ])
    error_message = "release-promoter solo crea releases (releaser), nunca aprueba."
  }
}

run "triggers_con_la_conexion_autorizada" {
  command = plan

  variables {
    github_connection_ready  = true
    release_triggers_enabled = true
  }

  assert {
    condition = (
      google_cloudbuild_trigger.release["backend"].service_account == "projects/sportapp-mgmt-test/serviceAccounts/cloud-build-backend@sportapp-mgmt-test.iam.gserviceaccount.com" &&
      google_cloudbuild_trigger.release["frontend"].service_account == "projects/sportapp-mgmt-test/serviceAccounts/cloud-build-frontend@sportapp-mgmt-test.iam.gserviceaccount.com" &&
      google_cloudbuild_trigger.promote[0].service_account == "projects/sportapp-mgmt-test/serviceAccounts/release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com"
    )
    error_message = "Cada trigger fija su cuenta administrada; ninguno usa la predeterminada de Cloud Build."
  }

  assert {
    condition = alltrue([
      for t in google_cloudbuild_trigger.release : (
        t.filename == "cloudbuild.release.yaml" && !t.disabled &&
        t.repository_event_config[0].push[0].tag == "^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$" &&
        t.location == "us-central1"
      )
    ])
    error_message = "Los triggers de release son regionales y solo responden a tags SemVer."
  }

  # Exactamente las sustituciones que declara cada cloudbuild.release.yaml.
  assert {
    condition = (
      google_cloudbuild_trigger.release["backend"].substitutions == tomap({
        _AR_LOCATION    = "us-central1"
        _AR_PROJECT     = "sportapp-prod-test"
        _AR_REPOSITORY  = "sportapp-backend"
        _RELEASE_BUCKET = "sportapp-mgmt-test-delivery-evidence-backend"
      }) &&
      google_cloudbuild_trigger.release["frontend"].substitutions == tomap({
        _REGISTRY       = "us-central1-docker.pkg.dev/sportapp-prod-test"
        _REPOSITORY     = "sportapp-frontend"
        _RELEASE_BUCKET = "sportapp-mgmt-test-delivery-evidence-frontend"
      })
    )
    error_message = "Las sustituciones de los triggers son explícitas y apuntan a su repositorio y bucket."
  }

  # Promotor: trigger manual (sin evento) sobre main de la plataforma.
  assert {
    condition = (
      length(google_cloudbuild_trigger.promote[0].repository_event_config) == 0 &&
      google_cloudbuild_trigger.promote[0].git_file_source[0].path == "cloudbuild.promote.yaml" &&
      google_cloudbuild_trigger.promote[0].source_to_build[0].ref == "refs/heads/main" &&
      google_cloudbuild_trigger.promote[0].substitutions["_DEPLOY_TOOLS_IMAGE"] == var.deploy_tools_image
    )
    error_message = "El promotor es un trigger manual interno sobre main de sport-app-platform."
  }
}

run "triggers_deshabilitables" {
  command = plan

  variables {
    github_connection_ready = true
  }

  assert {
    condition     = alltrue([for t in google_cloudbuild_trigger.release : t.disabled])
    error_message = "Los triggers de release quedan deshabilitados hasta que existan los cloudbuild.release.yaml."
  }
}

run "rechaza_aprobador_automatizado" {
  command = plan

  variables {
    approvers = ["serviceAccount:release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com"]
  }

  expect_failures = [var.approvers]
}

run "rechaza_triggers_sin_conexion" {
  command = plan

  variables {
    release_triggers_enabled = true
  }

  expect_failures = [var.release_triggers_enabled]
}

run "rechaza_imagen_de_herramientas_sin_digest" {
  command = plan

  variables {
    deploy_tools_image = "gcr.io/google.com/cloudsdktool/google-cloud-cli:latest"
  }

  expect_failures = [var.deploy_tools_image]
}

run "rechaza_identidad_terraform" {
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

# Una variable de Cloud Run que la plantilla de Cloud Deploy no declara haría que
# un rollout la quitara: el plan se detiene.
run "rechaza_parametros_distintos_de_la_plantilla" {
  command = plan

  override_data {
    target = data.terraform_remote_state.production
    values = {
      outputs = {
        artifact_registry_urls = {
          backend  = "us-central1-docker.pkg.dev/sportapp-prod-test/sportapp-backend"
          frontend = "us-central1-docker.pkg.dev/sportapp-prod-test/sportapp-frontend"
        }
        gke = { name = "sportapp-prod-gke", location = "us-central1", dns_endpoint = "gke-0000.us-central1.gke.goog", namespace = "sportapp", cluster_id = "projects/sportapp-prod-test/locations/us-central1/clusters/sportapp-prod-gke" }
        delivery_identities = {
          build_backend    = "cloud-build-backend@sportapp-mgmt-test.iam.gserviceaccount.com"
          build_frontend   = "cloud-build-frontend@sportapp-mgmt-test.iam.gserviceaccount.com"
          release_promoter = "release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com"
          deploy_execution = "cloud-deploy-execution@sportapp-mgmt-test.iam.gserviceaccount.com"
        }
        cloud_run_deploy_config = {
          bff-web = {
            name            = "bff-web", location = "projects/sportapp-prod-test/locations/us-central1", repository = "backend"
            service_account = "run-bff-web@sportapp-prod-test.iam.gserviceaccount.com", port = 8000, cpu = "1", memory = "512Mi"
            min_instances   = 1, max_instances = 10, concurrency = 80, timeout_seconds = 30
            vpc_network     = "sportapp-prod-vpc", vpc_subnetwork = "sportapp-prod-serverless"
            env = {
              APP_ENV                         = "production", LOG_LEVEL = "INFO", CORS_ALLOWED_ORIGINS = "https://web-1.us-central1.run.app"
              USERS_MANAGEMENT_BASE_URL       = "http://10.10.0.10", AFFILIATION_MANAGEMENT_BASE_URL = "http://10.10.0.11", TRAINING_MANAGEMENT_BASE_URL = "http://10.10.0.12"
              COMPLEMENTARY_SERVICES_BASE_URL = "http://10.10.0.13", EVENTS_MANAGEMENT_BASE_URL = "http://10.10.0.14"
            }
            secret_env = {}
            uri        = "https://bff-web-1.us-central1.run.app"
          }
          bff-mobile = {
            name            = "bff-mobile", location = "projects/sportapp-prod-test/locations/us-central1", repository = "backend"
            service_account = "run-bff-mobile@sportapp-prod-test.iam.gserviceaccount.com", port = 8000, cpu = "1", memory = "512Mi"
            min_instances   = 1, max_instances = 10, concurrency = 80, timeout_seconds = 30
            vpc_network     = "sportapp-prod-vpc", vpc_subnetwork = "sportapp-prod-serverless"
            env = {
              APP_ENV                      = "production", LOG_LEVEL = "INFO", USERS_MANAGEMENT_BASE_URL = "http://10.10.0.10", AFFILIATION_MANAGEMENT_BASE_URL = "http://10.10.0.11"
              TRAINING_MANAGEMENT_BASE_URL = "http://10.10.0.12", EVENTS_MANAGEMENT_BASE_URL = "http://10.10.0.14"
            }
            secret_env = {}
            uri        = "https://bff-mobile-1.us-central1.run.app"
          }
          web = {
            name            = "web", location = "projects/sportapp-prod-test/locations/us-central1", repository = "frontend"
            service_account = "run-web@sportapp-prod-test.iam.gserviceaccount.com", port = 8080, cpu = "1", memory = "512Mi"
            min_instances   = 1, max_instances = 10, concurrency = 80, timeout_seconds = 30
            vpc_network     = null, vpc_subnetwork = null
            env = {
              APP_ENV                       = "production", BFF_WEB_BASE_URL = "https://bff-web-1.us-central1.run.app"
              REGISTRATION_POLICIES_VERSION = "sportapp-c108-c108plus.v1", HEALTH_DATA_CONSENT_VERSION = "consentimiento-prueba.v1", NUEVA_VARIABLE = "x"
            }
            secret_env = {}
            uri        = "https://web-1.us-central1.run.app"
          }
        }
      }
    }
  }

  expect_failures = [google_clouddeploy_target.run]
}
