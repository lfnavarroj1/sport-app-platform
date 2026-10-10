# Ambiente de desarrollo en el Kubernetes de Docker Desktop.
#
# La plataforma aporta el namespace, el Secret con contraseñas generadas, la
# configuración y las dependencias compartidas (infra/kubernetes/local:
# PostgreSQL, emulador de Pub/Sub y sus tópicos). El backend aporta sus propios
# manifiestos (deploy/k8s/base); Kustomize los compone y Terraform los aplica.

locals {
  namespace = "sportapp-local"

  backend_components = [
    "users-management",
    "affiliation-management",
    "complementary-services",
    "training-management",
    "events-management",
    "third-party-management",
    "bff-web",
    "bff-mobile",
  ]

  # Claves que esperan postgres.yaml y los manifiestos del backend.
  password_keys = [
    "POSTGRES_ADMIN_PASSWORD",
    "USUARIOS_DB_PASSWORD",
    "AFILIACION_DB_PASSWORD",
    "SERVICIOS_DB_PASSWORD",
    "ENTRENAMIENTOS_DB_PASSWORD",
    "EVENTOS_DB_PASSWORD",
  ]

  # Kustomize exige rutas relativas a esta carpeta.
  shared_manifests  = "../../../kubernetes/local"
  backend_manifests = "${var.backend_path}/deploy/k8s/base"
}

resource "kubernetes_namespace_v1" "sportapp" {
  metadata {
    name = local.namespace
    labels = {
      "app.kubernetes.io/part-of"    = "sportapp"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# Solo letras y números: las contraseñas se insertan en URLs de conexión.
ephemeral "random_password" "database" {
  for_each = toset(local.password_keys)

  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "database" {
  metadata {
    name      = "sportapp-database"
    namespace = kubernetes_namespace_v1.sportapp.metadata[0].name
  }

  data_wo          = { for key, password in ephemeral.random_password.database : key => password.result }
  data_wo_revision = var.password_revision
}

data "kustomization_overlay" "sportapp" {
  namespace = local.namespace
  resources = concat(
    [local.shared_manifests],
    var.deploy_backend ? [local.backend_manifests] : [],
  )

  config_map_generator {
    name = "sportapp-runtime"
    literals = [
      "APP_ENV=local",
      "LOG_LEVEL=${var.log_level}",
      "DATABASE_HOST=postgres",
      "REGISTRATION_POLICIES_VERSION=${var.registration_policies_version}",
      "USERS_MANAGEMENT_BASE_URL=http://users-management",
      "PUBSUB_PROJECT_ID=sportapp-local",
      "PUBSUB_EMULATOR_HOST=pubsub-emulator:8085",
    ]
  }

  dynamic "images" {
    for_each = toset(local.backend_components)
    content {
      name    = "sportapp/${images.value}"
      new_tag = lookup(var.backend_image_tags, images.value, var.backend_image_tag)
    }
  }

  # Los manifiestos del backend están fuera de este repositorio.
  kustomize_options {
    load_restrictor = "none"
  }

  lifecycle {
    precondition {
      condition     = !var.deploy_backend || fileexists("${local.backend_manifests}/kustomization.yaml")
      error_message = "No se encontró deploy/k8s/base del backend. Ajuste backend_path o use deploy_backend = false."
    }
  }
}

# Orden recomendado por el proveedor: prioridad 0 (namespaces, CRD), 1 (resto)
# y 2 (webhooks).
resource "kustomization_resource" "p0" {
  for_each = data.kustomization_overlay.sportapp.ids_prio[0]

  manifest = data.kustomization_overlay.sportapp.manifests[each.value]

  depends_on = [kubernetes_secret_v1.database]
}

resource "kustomization_resource" "p1" {
  for_each = data.kustomization_overlay.sportapp.ids_prio[1]

  manifest = data.kustomization_overlay.sportapp.manifests[each.value]
  wait     = var.wait_for_rollout

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [kustomization_resource.p0]
}

resource "kustomization_resource" "p2" {
  for_each = data.kustomization_overlay.sportapp.ids_prio[2]

  manifest = data.kustomization_overlay.sportapp.manifests[each.value]

  depends_on = [kustomization_resource.p1]
}
