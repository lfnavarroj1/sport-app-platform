# Ambiente de desarrollo en el Kubernetes de Docker Desktop.
#
# La plataforma aporta el namespace, el Secret con contraseñas generadas, la
# configuración y las dependencias compartidas (infra/kubernetes/local:
# PostgreSQL, emulador de Pub/Sub y sus tópicos). Backend y frontend aportan sus
# propios manifiestos (deploy/k8s/base); Kustomize los compone y Terraform los aplica.

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
  shared_manifests   = "../../../kubernetes/local"
  backend_manifests  = "${var.backend_path}/deploy/k8s/base"
  frontend_manifests = "${var.frontend_path}/deploy/k8s/base"
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

# Clave Ed25519 desechable para firmar access tokens. Terraform la entrega al
# API de Kubernetes mediante el argumento write-only y nunca la guarda en el
# plan ni en el estado. El Secret conserva la clave entre reinicios de pods.
ephemeral "tls_private_key" "users_jwt" {
  algorithm = "ED25519"
}

resource "kubernetes_secret_v1" "users_jwt" {
  metadata {
    name      = "sportapp-users-jwt"
    namespace = kubernetes_namespace_v1.sportapp.metadata[0].name
    labels = {
      "app.kubernetes.io/part-of"    = "sportapp"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data_wo = {
    JWT_PRIVATE_KEY = ephemeral.tls_private_key.users_jwt.private_key_pem
  }
  data_wo_revision = var.jwt_key_revision
}

data "kustomization_overlay" "sportapp" {
  namespace = local.namespace
  resources = concat(
    [local.shared_manifests],
    var.deploy_backend ? [local.backend_manifests] : [],
    var.deploy_frontend ? [local.frontend_manifests] : [],
  )

  config_map_generator {
    name = "sportapp-runtime"
    literals = [
      "APP_ENV=local",
      "LOG_LEVEL=${var.log_level}",
      "DATABASE_HOST=postgres",
      "REGISTRATION_POLICIES_VERSION=${var.registration_policies_version}",
      "HEALTH_DATA_CONSENT_VERSION=${var.health_data_consent_version}",
      "AFFILIATION_EXPECTED_CATALOG_VERSION=${var.affiliation_expected_catalog_version}",
      "USERS_MANAGEMENT_BASE_URL=http://users-management",
      "PUBSUB_PROJECT_ID=sportapp-local",
      "PUBSUB_EMULATOR_HOST=pubsub-emulator:8085",
      # El navegador llama al BFF por el acceso bff-web-local.
      "BFF_WEB_BASE_URL=http://localhost:18080",
      # Orígenes que el BFF web acepta por CORS: la web en el clúster y npm start.
      "CORS_ALLOWED_ORIGINS=http://localhost:18082,http://localhost:4200",
    ]
  }

  dynamic "images" {
    for_each = toset(local.backend_components)
    content {
      name    = "sportapp/${images.value}"
      new_tag = lookup(var.backend_image_tags, images.value, var.backend_image_tag)
    }
  }

  images {
    name    = "sportapp/web"
    new_tag = var.frontend_image_tag
  }

  # El catálogo esperado lo fija el ambiente desde sportapp-runtime (ADR-036),
  # en lugar del valor que trae el manifiesto del backend.
  dynamic "patches" {
    for_each = var.deploy_backend ? [1] : []
    content {
      target {
        kind = "Deployment"
        name = "affiliation-management"
      }
      patch = <<-EOT
        apiVersion: apps/v1
        kind: Deployment
        metadata:
          name: affiliation-management
        spec:
          template:
            spec:
              containers:
                - name: app
                  env:
                    - name: AFFILIATION_EXPECTED_CATALOG_VERSION
                      value: null
                      valueFrom:
                        configMapKeyRef:
                          name: sportapp-runtime
                          key: AFFILIATION_EXPECTED_CATALOG_VERSION
      EOT
    }
  }

  # Los manifiestos de backend y frontend están fuera de este repositorio.
  kustomize_options {
    load_restrictor = "none"
  }

  lifecycle {
    precondition {
      condition     = !var.deploy_backend || fileexists("${local.backend_manifests}/kustomization.yaml")
      error_message = "No se encontró deploy/k8s/base del backend. Ajuste backend_path o use deploy_backend = false."
    }
    precondition {
      condition     = !var.deploy_frontend || fileexists("${local.frontend_manifests}/kustomization.yaml")
      error_message = "No se encontró deploy/k8s/base del frontend. Ajuste frontend_path o use deploy_frontend = false."
    }
  }
}

# Orden recomendado por el proveedor: prioridad 0 (namespaces, CRD), 1 (resto)
# y 2 (webhooks). La prioridad 1 se divide en dos fases: primero configuración y
# Services, después las cargas (Deployments, StatefulSets y Jobs). Si van juntas,
# las cargas que esperan su rollout pueden ocupar todos los cupos de paralelismo
# de Terraform y dejar en cola el ConfigMap que necesitan para arrancar.
#
# Afiliación tiene una fase propia (ADR-024): su migración de catálogo debe
# terminar antes de habilitar sus réplicas, y el proveedor no espera Jobs.
locals {
  ids_p1          = data.kustomization_overlay.sportapp.ids_prio[1]
  ids_p1_workload = toset([for id in local.ids_p1 : id if can(regex("^(apps|batch)/", id))])
  ids_p1_config   = setsubtract(local.ids_p1, local.ids_p1_workload)

  ids_affiliation_migrations = toset([for id in local.ids_p1_workload : id if can(regex("^batch/Job/[^/]+/affiliation-management-migrate-", id))])
  ids_affiliation_workloads  = toset([for id in local.ids_p1_workload : id if can(regex("^apps/Deployment/[^/]+/affiliation-management(-|$)", id))])
  ids_other_workloads        = setsubtract(local.ids_p1_workload, setunion(local.ids_affiliation_migrations, local.ids_affiliation_workloads))
}

resource "kustomization_resource" "p0" {
  for_each = data.kustomization_overlay.sportapp.ids_prio[0]

  manifest = data.kustomization_overlay.sportapp.manifests[each.value]

  depends_on = [kubernetes_secret_v1.database]
}

resource "kustomization_resource" "p1" {
  for_each = local.ids_p1_config

  manifest = data.kustomization_overlay.sportapp.manifests[each.value]

  depends_on = [
    kustomization_resource.p0,
    kubernetes_secret_v1.users_jwt,
  ]
}

resource "kustomization_resource" "p1_workloads" {
  for_each = local.ids_other_workloads

  manifest = data.kustomization_overlay.sportapp.manifests[each.value]
  wait     = var.wait_for_rollout

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [kustomization_resource.p1]
}

# El Job reintenta con espera creciente mientras PostgreSQL termina de iniciar.
resource "kustomization_resource" "affiliation_migrations" {
  for_each = local.ids_affiliation_migrations

  manifest = data.kustomization_overlay.sportapp.manifests[each.value]

  depends_on = [kustomization_resource.p1]
}

# Se repite cada vez que el Job cambia (por ejemplo, un tag nuevo lo reemplaza).
resource "terraform_data" "affiliation_migrations_complete" {
  for_each = local.ids_affiliation_migrations

  triggers_replace = kustomization_resource.affiliation_migrations[each.key].manifest

  # KUBECONFIG por entorno: evita comillas, que cmd (Windows) y sh tratan distinto.
  provisioner "local-exec" {
    command = "kubectl --context ${var.kube_context} --namespace ${local.namespace} wait --for=condition=complete --timeout=10m job/${split("/", each.key)[3]}"
    environment = {
      KUBECONFIG = pathexpand(var.kubeconfig_path)
    }
  }
}

resource "kustomization_resource" "affiliation_workloads" {
  for_each = local.ids_affiliation_workloads

  manifest = data.kustomization_overlay.sportapp.manifests[each.value]
  wait     = var.wait_for_rollout

  timeouts {
    create = "10m"
    update = "10m"
  }

  depends_on = [
    kustomization_resource.p1,
    terraform_data.affiliation_migrations_complete,
  ]
}

# Estados creados antes de la fase de Afiliación: mover, no recrear.
moved {
  from = kustomization_resource.p1_workloads["batch/Job/sportapp-local/affiliation-management-migrate-main"]
  to   = kustomization_resource.affiliation_migrations["batch/Job/sportapp-local/affiliation-management-migrate-main"]
}

moved {
  from = kustomization_resource.p1_workloads["apps/Deployment/sportapp-local/affiliation-management"]
  to   = kustomization_resource.affiliation_workloads["apps/Deployment/sportapp-local/affiliation-management"]
}

moved {
  from = kustomization_resource.p1_workloads["apps/Deployment/sportapp-local/affiliation-management-free-plan-consumer"]
  to   = kustomization_resource.affiliation_workloads["apps/Deployment/sportapp-local/affiliation-management-free-plan-consumer"]
}

moved {
  from = kustomization_resource.p1_workloads["apps/Deployment/sportapp-local/affiliation-management-outbox-publisher"]
  to   = kustomization_resource.affiliation_workloads["apps/Deployment/sportapp-local/affiliation-management-outbox-publisher"]
}

resource "kustomization_resource" "p2" {
  for_each = data.kustomization_overlay.sportapp.ids_prio[2]

  manifest = data.kustomization_overlay.sportapp.manifests[each.value]

  depends_on = [
    kustomization_resource.p1_workloads,
    kustomization_resource.affiliation_workloads,
  ]
}
