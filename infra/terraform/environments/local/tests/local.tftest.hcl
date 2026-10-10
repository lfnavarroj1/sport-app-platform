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

# random no se simula: el mock aún no admite recursos efímeros y el proveedor
# real no tiene efectos externos.

run "solo_dependencias_compartidas" {
  command = plan

  variables {
    deploy_backend = false
  }

  assert {
    condition     = kubernetes_namespace_v1.sportapp.metadata[0].name == "sportapp-local"
    error_message = "El ambiente usa el namespace sportapp-local."
  }
}

run "rechaza_contexto_distinto_de_docker_desktop" {
  command = plan

  variables {
    deploy_backend = false
    kube_context   = "gke_proyecto-final-miso-416801_us-east1_cluster-proyecto-final"
  }

  expect_failures = [var.kube_context]
}

run "rechaza_ruta_de_backend_inexistente" {
  command = plan

  variables {
    backend_path = "../no-existe"
  }

  expect_failures = [data.kustomization_overlay.sportapp]
}
