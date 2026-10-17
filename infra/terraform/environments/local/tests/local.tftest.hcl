# Pruebas sin clúster: proveedores de Kubernetes y Kustomize simulados.
# Ejecutar: terraform init && terraform test

mock_provider "kubernetes" {}

mock_provider "kustomization" {
  mock_data "kustomization_overlay" {
    defaults = {
      ids_prio  = [[], [], []]
      manifests = {}
    }
  }
}

# random y tls no se simulan: el mock aún no admite recursos efímeros y los
# proveedores reales no tienen efectos externos.

run "solo_dependencias_compartidas" {
  command = plan

  variables {
    deploy_backend  = false
    deploy_frontend = false
  }

  assert {
    condition     = kubernetes_namespace_v1.sportapp.metadata[0].name == "sportapp-local"
    error_message = "El ambiente usa el namespace sportapp-local."
  }

  assert {
    condition     = kubernetes_secret_v1.users_jwt.metadata[0].name == "sportapp-users-jwt"
    error_message = "El ambiente crea el Secret de firma JWT requerido por users-management."
  }

  assert {
    condition     = kubernetes_secret_v1.users_jwt.data_wo_revision == var.jwt_key_revision
    error_message = "La rotación de la clave JWT está controlada por jwt_key_revision."
  }

  assert {
    condition     = contains(data.kustomization_overlay.sportapp.config_map_generator[0].literals, "HEALTH_DATA_CONSENT_VERSION=local-dev")
    error_message = "El ConfigMap sportapp-runtime define HEALTH_DATA_CONSENT_VERSION, sin la cual users-management no arranca."
  }
}

# HU001: una sola versión de políticas para users-management y web, y el
# catálogo que Afiliación exige para quedar lista.
run "configuracion_de_hu001" {
  command = plan

  variables {
    deploy_frontend = false
  }

  assert {
    condition = alltrue([
      for literal in [
        "REGISTRATION_POLICIES_VERSION=sportapp-c108-c108plus.v1",
        "AFFILIATION_EXPECTED_CATALOG_VERSION=plans-2026-10-13.v1",
      ] : contains(data.kustomization_overlay.sportapp.config_map_generator[0].literals, literal)
    ])
    error_message = "sportapp-runtime publica la versión de políticas y el catálogo aprobados."
  }

  assert {
    condition = (
      data.kustomization_overlay.sportapp.patches[0].target[0].name == "affiliation-management" &&
      strcontains(data.kustomization_overlay.sportapp.patches[0].patch, "key: AFFILIATION_EXPECTED_CATALOG_VERSION")
    )
    error_message = "affiliation-management toma el catálogo esperado de sportapp-runtime."
  }
}

run "rechaza_version_de_politicas_demasiado_larga" {
  command = plan

  variables {
    deploy_backend                = false
    deploy_frontend               = false
    registration_policies_version = "sportapp-version-de-politicas-demasiado-larga"
  }

  expect_failures = [var.registration_policies_version]
}

run "rechaza_contexto_distinto_de_docker_desktop" {
  command = plan

  variables {
    deploy_backend  = false
    deploy_frontend = false
    kube_context    = "gke_proyecto-final-miso-416801_us-east1_cluster-proyecto-final"
  }

  expect_failures = [var.kube_context]
}

run "rechaza_ruta_de_backend_inexistente" {
  command = plan

  variables {
    backend_path    = "../no-existe"
    deploy_frontend = false
  }

  expect_failures = [data.kustomization_overlay.sportapp]
}

run "rechaza_ruta_de_frontend_inexistente" {
  command = plan

  variables {
    deploy_backend = false
    frontend_path  = "../no-existe"
  }

  expect_failures = [data.kustomization_overlay.sportapp]
}
