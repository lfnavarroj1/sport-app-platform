# Propiedad Terraform / Cloud Deploy del servicio Cloud Run, con proveedor
# simulado (no crea recursos). Ejecutar desde modules/gcp/cloud-run:
#   terraform init -backend=false
#   terraform test

mock_provider "google" {}

variables {
  project_id            = "sportapp-test"
  region                = "us-central1"
  name                  = "bff-web"
  image                 = "us-central1-docker.pkg.dev/sportapp-test/sportapp-backend/bff-web@sha256:1111111111111111111111111111111111111111111111111111111111111111"
  service_account       = "run-bff-web@sportapp-test.iam.gserviceaccount.com"
  port                  = 8000
  cpu                   = "1"
  memory                = "512Mi"
  min_instances         = 1
  max_instances         = 10
  concurrency           = 80
  timeout_seconds       = 30
  allow_unauthenticated = false
  deletion_protection   = false
  env                   = { APP_ENV = "production", LOG_LEVEL = "INFO" }
  deployer_members = {
    deploy-execution = "serviceAccount:cloud-deploy-execution@sportapp-mgmt-test.iam.gserviceaccount.com"
  }
}

# 1. Terraform crea el servicio con el digest inicial aprobado.
run "crea_la_primera_revision" {
  command = apply

  assert {
    condition     = google_cloud_run_v2_service.this.template[0].containers[0].image == var.image
    error_message = "La primera revisión usa el digest inicial."
  }

  assert {
    condition = (
      google_cloud_run_v2_service_iam_member.deployers["deploy-execution"].role == "roles/run.developer" &&
      google_cloud_run_v2_service_iam_member.deployers["deploy-execution"].name == "bff-web"
    )
    error_message = "Cloud Deploy publica revisiones solo en este servicio."
  }
}

# 2. Cloud Deploy promueve otro digest: un plan con la variable antigua o una
#    nueva no devuelve el servicio a la imagen anterior.
run "no_restaura_un_digest_posterior" {
  command = plan

  variables {
    image = "us-central1-docker.pkg.dev/sportapp-test/sportapp-backend/bff-web@sha256:2222222222222222222222222222222222222222222222222222222222222222"
  }

  assert {
    condition     = google_cloud_run_v2_service.this.template[0].containers[0].image == "us-central1-docker.pkg.dev/sportapp-test/sportapp-backend/bff-web@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    error_message = "Terraform no reconcilia la imagen: la administra Cloud Deploy."
  }
}

# 3. Un cambio de infraestructura sigue detectándose y aplicándose.
run "detecta_cambios_de_configuracion" {
  command = plan

  variables {
    env           = { APP_ENV = "production", LOG_LEVEL = "DEBUG" }
    max_instances = 20
  }

  assert {
    condition = (
      anytrue([for e in google_cloud_run_v2_service.this.template[0].containers[0].env : e.name == "LOG_LEVEL" && e.value == "DEBUG"]) &&
      google_cloud_run_v2_service.this.template[0].scaling[0].max_instance_count == 20
    )
    error_message = "Variables y escalado siguen bajo Terraform."
  }
}

run "rechaza_tag_mutable" {
  command = plan

  variables {
    image = "us-central1-docker.pkg.dev/sportapp-test/sportapp-backend/bff-web:latest"
  }

  expect_failures = [var.image]
}
