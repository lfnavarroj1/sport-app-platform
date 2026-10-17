# Pruebas de plan sin credenciales ni clúster: google y kubernetes simulados,
# estado de environments/production reemplazado y Kustomize real sobre el clon
# del backend (carpeta hermana de platform). Ejecutar:
#   terraform init -backend=false
#   terraform test

# google real con un token ficticio: google_client_config no contacta a Google.
provider "google" {
  project      = "sportapp-test"
  region       = "us-central1"
  access_token = "token-de-prueba"
}
mock_provider "kubernetes" {}

override_data {
  target = data.terraform_remote_state.platform
  values = {
    outputs = {
      artifact_registry_url = "us-central1-docker.pkg.dev/sportapp-test/sportapp"
      gke                   = { name = "sportapp-prod-gke", location = "us-central1", dns_endpoint = "gke-0000.us-central1.gke.goog", namespace = "sportapp" }
      # Mismas KSA que gke_workloads de modules/gcp/platform.
      gke_workload_identities = {
        "users-management"                          = "gke-users-api@sportapp-test.iam.gserviceaccount.com"
        "users-management-outbox-publisher"         = "gke-users-outbox@sportapp-test.iam.gserviceaccount.com"
        "users-management-read-projector"           = "gke-users-projector@sportapp-test.iam.gserviceaccount.com"
        "users-management-migrate"                  = "gke-users-migrate@sportapp-test.iam.gserviceaccount.com"
        "affiliation-management"                    = "gke-affiliation-api@sportapp-test.iam.gserviceaccount.com"
        "affiliation-management-free-plan-consumer" = "gke-affiliation-consumer@sportapp-test.iam.gserviceaccount.com"
        "affiliation-management-outbox-publisher"   = "gke-affiliation-outbox@sportapp-test.iam.gserviceaccount.com"
        "affiliation-management-migrate"            = "gke-affiliation-migrate@sportapp-test.iam.gserviceaccount.com"
        "complementary-services"                    = "gke-services-api@sportapp-test.iam.gserviceaccount.com"
        "complementary-services-outbox-publisher"   = "gke-services-outbox@sportapp-test.iam.gserviceaccount.com"
        "complementary-services-migrate"            = "gke-services-migrate@sportapp-test.iam.gserviceaccount.com"
        "training-management"                       = "gke-training-api@sportapp-test.iam.gserviceaccount.com"
        "training-management-outbox-publisher"      = "gke-training-outbox@sportapp-test.iam.gserviceaccount.com"
        "training-management-read-projector"        = "gke-training-projector@sportapp-test.iam.gserviceaccount.com"
        "training-management-migrate"               = "gke-training-migrate@sportapp-test.iam.gserviceaccount.com"
        "events-management"                         = "gke-events-api@sportapp-test.iam.gserviceaccount.com"
        "events-management-outbox-publisher"        = "gke-events-outbox@sportapp-test.iam.gserviceaccount.com"
        "events-management-read-projector"          = "gke-events-projector@sportapp-test.iam.gserviceaccount.com"
        "events-management-migrate"                 = "gke-events-migrate@sportapp-test.iam.gserviceaccount.com"
        "third-party-management"                    = "gke-third-party@sportapp-test.iam.gserviceaccount.com"
      }
      cloud_sql = {
        instance_name    = "sportapp-prod-pg"
        connection_name  = "sportapp-test:us-central1:sportapp-prod-pg"
        private_ip       = "10.20.0.3"
        password_secrets = { usuarios = "db-password-usuarios", afiliacion = "db-password-afiliacion", servicios = "db-password-servicios", entrenamientos = "db-password-entrenamientos", eventos = "db-password-eventos" }
      }
      gke_internal_apis = {
        users-management       = "10.10.0.10"
        affiliation-management = "10.10.0.11"
        training-management    = "10.10.0.12"
        complementary-services = "10.10.0.13"
        events-management      = "10.10.0.14"
      }
      gke_internal_source_ranges = ["10.10.16.0/26"]
      runtime_config = {
        app_env                              = "production"
        project_id                           = "sportapp-test"
        database_host                        = "10.20.0.3"
        registration_policies_version        = "sportapp-c108-c108plus.v1"
        health_data_consent_version          = "consentimiento-prueba.v1"
        affiliation_expected_catalog_version = "plans-2026-10-13.v1"
      }
    }
  }
}

# El plan de recursos no contacta el clúster: se prueba lo que Kustomize renderiza.
override_resource {
  target = kustomization_resource.config
}

override_resource {
  target = kustomization_resource.workloads
}

variables {
  project_id   = "sportapp-test"
  state_bucket = "sportapp-mgmt-test-tfstate"
  # Sin credenciales no se puede leer Secret Manager; el check lo advierte.
  sync_secrets = false
  backend_path = "../../../../../backend"
  image_digests = {
    users-management       = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    affiliation-management = "sha256:2222222222222222222222222222222222222222222222222222222222222222"
    complementary-services = "sha256:3333333333333333333333333333333333333333333333333333333333333333"
    training-management    = "sha256:4444444444444444444444444444444444444444444444444444444444444444"
    events-management      = "sha256:5555555555555555555555555555555555555555555555555555555555555555"
    third-party-management = "sha256:6666666666666666666666666666666666666666666666666666666666666666"
  }
}

run "despliegue_completo_en_gke" {
  command = plan

  # sync_secrets = false: el check advierte que los Secrets no se gestionan.
  expect_failures = [check.secrets_sincronizados]

  # Vista de despliegue: servicios core y workers CQRS en GKE; los BFF van a Cloud Run.
  assert {
    condition = toset(output.workloads) == toset([
      "users-management", "users-management-outbox-publisher", "users-management-read-projector",
      "affiliation-management", "affiliation-management-free-plan-consumer", "affiliation-management-outbox-publisher",
      "complementary-services", "complementary-services-outbox-publisher",
      "training-management", "training-management-outbox-publisher", "training-management-read-projector",
      "events-management", "events-management-outbox-publisher", "events-management-read-projector",
      "third-party-management",
    ])
    error_message = "GKE recibe todos los Deployments del backend salvo bff-web y bff-mobile."
  }

  assert {
    condition     = length(output.migrations) == 8 && length(kubernetes_manifest.migration) == 8
    error_message = "Los 8 Jobs de migración del backend se aplican y se esperan antes de las cargas."
  }

  assert {
    condition     = alltrue([for k in keys(data.kustomization_overlay.backend.manifests) : !strcontains(k, "/bff-")])
    error_message = "bff-web y bff-mobile no se despliegan en GKE."
  }

  # Workload Identity: cada carga y cada Job tienen su KSA, y la KSA existe.
  assert {
    condition = alltrue([
      for id in local.ids_workload : (
        jsondecode(data.kustomization_overlay.backend.manifests[id]).spec.template.spec.serviceAccountName == jsondecode(data.kustomization_overlay.backend.manifests[id]).metadata.name &&
        contains(keys(local.identities), jsondecode(data.kustomization_overlay.backend.manifests[id]).metadata.name)
      )
    ])
    error_message = "Cada Deployment usa la KSA de su nombre y esa KSA tiene identidad en GCP."
  }

  assert {
    condition = alltrue([
      for id in local.ids_jobs : contains(keys(local.identities), jsondecode(data.kustomization_overlay.backend.manifests[id]).spec.template.spec.serviceAccountName) &&
      endswith(jsondecode(data.kustomization_overlay.backend.manifests[id]).spec.template.spec.serviceAccountName, "-migrate")
    ])
    error_message = "Cada Job de migración usa la KSA de migración de su servicio."
  }

  assert {
    condition = alltrue([
      for id in setunion(local.ids_workload, local.ids_jobs) : alltrue([
        for c in jsondecode(data.kustomization_overlay.backend.manifests[id]).spec.template.spec.containers :
        startswith(c.image, "us-central1-docker.pkg.dev/sportapp-test/sportapp/") && strcontains(c.image, "@sha256:")
      ])
    ])
    error_message = "Todas las imágenes vienen de Artifact Registry y se fijan por digest."
  }

  assert {
    condition = alltrue([
      for name, ip in {
        users-management       = "10.10.0.10"
        affiliation-management = "10.10.0.11"
        training-management    = "10.10.0.12"
        complementary-services = "10.10.0.13"
        events-management      = "10.10.0.14"
        } : (
        jsondecode(data.kustomization_overlay.backend.manifests["_/Service/sportapp/${name}"]).spec.type == "LoadBalancer" &&
        jsondecode(data.kustomization_overlay.backend.manifests["_/Service/sportapp/${name}"]).spec.loadBalancerIP == ip &&
        jsondecode(data.kustomization_overlay.backend.manifests["_/Service/sportapp/${name}"]).spec.loadBalancerSourceRanges == ["10.10.16.0/26"] &&
        jsondecode(data.kustomization_overlay.backend.manifests["_/Service/sportapp/${name}"]).metadata.annotations["networking.gke.io/load-balancer-type"] == "Internal"
      )
    ])
    error_message = "Las APIs que llaman los BFF se exponen por balanceador interno en su IP reservada y solo para la subred de Cloud Run."
  }

  assert {
    condition = alltrue([
      for name in local.gke_components : jsondecode(data.kustomization_overlay.backend.manifests["apps/Deployment/sportapp/${name}"]).spec.replicas == 2
    ])
    error_message = "Cada API corre con dos réplicas."
  }

  assert {
    condition = alltrue([
      for literal in [
        "APP_ENV=production",
        "DATABASE_HOST=10.20.0.3",
        "PUBSUB_PROJECT_ID=sportapp-test",
        "REGISTRATION_POLICIES_VERSION=sportapp-c108-c108plus.v1",
        "HEALTH_DATA_CONSENT_VERSION=consentimiento-prueba.v1",
        "AFFILIATION_EXPECTED_CATALOG_VERSION=plans-2026-10-13.v1",
      ] : contains(data.kustomization_overlay.backend.config_map_generator[0].literals, literal)
    ]) && alltrue([for l in data.kustomization_overlay.backend.config_map_generator[0].literals : !startswith(l, "PUBSUB_EMULATOR_HOST")])
    error_message = "sportapp-runtime usa Cloud SQL privado, Pub/Sub administrado y las versiones del ambiente."
  }

  assert {
    condition = anytrue([
      for e in jsondecode(data.kustomization_overlay.backend.manifests["apps/Deployment/sportapp/affiliation-management"]).spec.template.spec.containers[0].env :
      e.name == "AFFILIATION_EXPECTED_CATALOG_VERSION" && try(e.valueFrom.configMapKeyRef.key, "") == "AFFILIATION_EXPECTED_CATALOG_VERSION" && try(e.value, null) == null
    ])
    error_message = "affiliation-management toma el catálogo esperado de sportapp-runtime."
  }

  assert {
    condition     = toset(keys(kubernetes_service_account_v1.workload)) == toset(keys(local.identities))
    error_message = "Se crea una KSA por identidad de carga."
  }
}

run "rechaza_imagen_sin_digest" {
  command = plan

  variables {
    image_digests = {
      users-management = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    }
  }

  expect_failures = [var.image_digests, check.secrets_sincronizados]
}

run "rechaza_backend_inexistente" {
  command = plan

  variables {
    backend_path = "../no-existe"
  }

  expect_failures = [data.kustomization_overlay.backend, check.secrets_sincronizados]
}
