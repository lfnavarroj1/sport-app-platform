# Pruebas de plan sin credenciales ni clúster: kubernetes simulado, estado de
# environments/production reemplazado y Kustomize real sobre el clon del
# backend (carpeta hermana de platform). Ejecutar:
#   terraform init -backend=false
#   terraform test

# google real con un token ficticio: google_client_config no contacta a Google
# y, con sync_secrets = false, no se lee Secret Manager.
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
      gke = { name = "sportapp-prod-gke", location = "us-central1", dns_endpoint = "gke-0000.us-central1.gke.goog", namespace = "sportapp", cluster_id = "projects/sportapp-test/locations/us-central1/clusters/sportapp-prod-gke" }
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
      delivery_identities = {
        build_backend    = "cloud-build-backend@sportapp-mgmt-test.iam.gserviceaccount.com"
        build_frontend   = "cloud-build-frontend@sportapp-mgmt-test.iam.gserviceaccount.com"
        release_promoter = "release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com"
        deploy_execution = "cloud-deploy-execution@sportapp-mgmt-test.iam.gserviceaccount.com"
      }
    }
  }
}

# El plan de los Services no contacta el clúster: se prueba lo que Kustomize renderiza.
override_resource {
  target = kustomization_resource.services
}

variables {
  project_id                  = "sportapp-test"
  state_bucket                = "sportapp-mgmt-test-tfstate-production"
  impersonate_service_account = "tf-apply-production@sportapp-mgmt-test.iam.gserviceaccount.com"
  backend_path                = "../../../../../backend"
  # Sin credenciales no se puede leer Secret Manager; el check lo advierte.
  sync_secrets = false
}

run "base_kubernetes_sin_cargas" {
  command = plan

  # sync_secrets = false: el check advierte que los Secrets no se gestionan.
  expect_failures = [check.secrets_sincronizados]

  # Terraform no administra Deployments ni Jobs: los aplica Cloud Deploy.
  assert {
    condition     = alltrue([for id in keys(kustomization_resource.services) : startswith(id, "_/Service/")]) && length(kustomization_resource.services) > 0
    error_message = "production-workloads solo aplica Services; apps/* y batch/* pertenecen a Cloud Deploy."
  }

  assert {
    condition = toset(output.services) == toset([
      "users-management", "affiliation-management", "complementary-services",
      "training-management", "events-management", "third-party-management",
    ])
    error_message = "Terraform administra los Services del backend en GKE, sin los de bff-web y bff-mobile."
  }

  # El render contiene Deployments y Jobs del backend (Cloud Deploy los aplica);
  # ninguno entra en los recursos de esta raíz.
  assert {
    condition = (
      length([for id in local.ids_rendered : id if can(regex("^(apps|batch)/", id))]) > 0 &&
      length([for id in keys(kustomization_resource.services) : id if can(regex("^(apps|batch)/", id))]) == 0
    )
    error_message = "Ningún Deployment, Job de migración o digest promovido queda bajo Terraform."
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
    condition = (
      kubernetes_config_map_v1.runtime.metadata[0].name == "sportapp-runtime" &&
      kubernetes_config_map_v1.runtime.data["APP_ENV"] == "production" &&
      kubernetes_config_map_v1.runtime.data["DATABASE_HOST"] == "10.20.0.3" &&
      kubernetes_config_map_v1.runtime.data["AFFILIATION_EXPECTED_CATALOG_VERSION"] == "plans-2026-10-13.v1" &&
      !contains(keys(kubernetes_config_map_v1.runtime.data), "PUBSUB_EMULATOR_HOST")
    )
    error_message = "sportapp-runtime (nombre fijo) usa Cloud SQL privado, Pub/Sub administrado y las versiones del ambiente."
  }

  assert {
    condition     = toset(keys(kubernetes_service_account_v1.workload)) == toset(keys(local.identities))
    error_message = "Se crea una KSA por identidad de carga y por migración."
  }

  # RBAC de Cloud Deploy: solo el namespace, sin borrar ni leer secretos.
  assert {
    condition = (
      kubernetes_role_binding_v1.cloud_deploy.subject[0].kind == "User" &&
      kubernetes_role_binding_v1.cloud_deploy.subject[0].name == "cloud-deploy-execution@sportapp-mgmt-test.iam.gserviceaccount.com" &&
      kubernetes_role_binding_v1.cloud_deploy.role_ref[0].kind == "Role"
    )
    error_message = "cloud-deploy-execution opera con un Role del namespace, nunca con un ClusterRole."
  }

  assert {
    condition = alltrue([
      for rule in kubernetes_role_v1.cloud_deploy.rule : (
        !contains(rule.verbs, "delete") && !contains(rule.verbs, "deletecollection") && !contains(rule.verbs, "*") &&
        !contains(rule.resources, "secrets") && !contains(rule.resources, "configmaps") &&
        !contains(rule.resources, "roles") && !contains(rule.resources, "rolebindings") &&
        !contains(rule.resources, "serviceaccounts") && !contains(rule.resources, "services")
      )
    ])
    error_message = "Cloud Deploy no borra objetos ni modifica Secrets, ConfigMaps, RBAC, KSA o Services."
  }
}

run "rechaza_backend_inexistente" {
  command = plan

  variables {
    backend_path = "../no-existe"
  }

  expect_failures = [data.kustomization_overlay.backend, check.secrets_sincronizados]
}

run "rechaza_ejecucion_sin_impersonar_terraform" {
  command = plan

  variables {
    impersonate_service_account = "cloud-deploy-execution@sportapp-mgmt-test.iam.gserviceaccount.com"
  }

  expect_failures = [var.impersonate_service_account, check.secrets_sincronizados]
}
