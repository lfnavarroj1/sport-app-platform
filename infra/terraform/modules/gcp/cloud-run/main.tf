# Servicio Cloud Run con identidad propia, imagen por digest y, si se indica,
# salida directa a la VPC para alcanzar servicios internos de GKE.
#
# Propiedad: Terraform administra el servicio base (identidad, red, variables,
# secretos, escalado, sondas y acceso). La imagen solo se usa para crear la
# primera revisión; después Cloud Deploy administra imagen, revisión y tráfico,
# y Terraform no los reconcilia (lifecycle.ignore_changes).

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.6"
    }
  }
}

resource "google_cloud_run_v2_service" "this" {
  project             = var.project_id
  name                = var.name
  location            = var.region
  ingress             = var.ingress
  deletion_protection = var.deletion_protection

  dynamic "binary_authorization" {
    for_each = var.binary_authorization_enabled ? [1] : []
    content {
      use_default = true
    }
  }

  template {
    service_account                  = var.service_account
    timeout                          = "${var.timeout_seconds}s"
    max_instance_request_concurrency = var.concurrency

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    dynamic "vpc_access" {
      for_each = var.vpc_subnetwork == null ? [] : [1]
      content {
        egress = "PRIVATE_RANGES_ONLY"
        network_interfaces {
          network    = var.vpc_network
          subnetwork = var.vpc_subnetwork
        }
      }
    }

    containers {
      image = var.image

      ports {
        container_port = var.port
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      dynamic "env" {
        for_each = var.env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      dynamic "startup_probe" {
        for_each = var.startup_probe_path == null ? [] : [var.startup_probe_path]
        content {
          period_seconds    = 5
          failure_threshold = 12
          http_get {
            path = startup_probe.value
            port = var.port
          }
        }
      }

      dynamic "liveness_probe" {
        for_each = var.liveness_probe_path == null ? [] : [var.liveness_probe_path]
        content {
          period_seconds    = 20
          failure_threshold = 3
          http_get {
            path = liveness_probe.value
            port = var.port
          }
        }
      }
    }
  }

  # Solo los campos que escribe un rollout de Cloud Deploy:
  # - la imagen de la revisión (el digest promovido);
  # - el nombre de la revisión y la asignación de tráfico;
  # - etiquetas y anotaciones de la plantilla con los datos de la release;
  # - el cliente que hizo el último despliegue.
  # Cualquier otro campo (variables, identidad, red, escalado, sondas) sigue
  # bajo Terraform y un cambio se detecta y aplica.
  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      template[0].revision,
      template[0].labels,
      template[0].annotations,
      traffic,
      client,
      client_version,
    ]
  }
}

# Cloud Deploy publica revisiones en este servicio; no administra ningún otro.
resource "google_cloud_run_v2_service_iam_member" "deployers" {
  for_each = var.deployer_members

  project  = var.project_id
  location = google_cloud_run_v2_service.this.location
  name     = google_cloud_run_v2_service.this.name
  role     = "roles/run.developer"
  member   = each.value
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  count = var.allow_unauthenticated ? 1 : 0

  project  = var.project_id
  location = google_cloud_run_v2_service.this.location
  name     = google_cloud_run_v2_service.this.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "uri" {
  description = "URL pública del servicio."
  value       = google_cloud_run_v2_service.this.uri
}

output "name" {
  description = "Nombre del servicio."
  value       = google_cloud_run_v2_service.this.name
}
