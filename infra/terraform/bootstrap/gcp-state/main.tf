# Fundación que debe existir antes de las raíces de environments/:
# - un bucket de estado versionado por ambiente en el proyecto de gestión;
# - por ambiente, una cuenta tf-plan (lectura) y una tf-apply (cambios) que
#   solo pueden impersonar los operadores humanos declarados;
# - para el ambiente con entrega, las identidades internas de GCP que
#   construyen (Cloud Build), promueven y despliegan (Cloud Deploy);
# - presupuestos con alertas por proyecto (no limitan el gasto por sí solos).
#
# GitHub no recibe identidad GCP: no hay Workload Identity Federation, ningún
# repositorio es principal de una cuenta y Terraform solo se ejecuta desde la
# estación del operador (ADC + impersonación de tf-apply-<ambiente>).

locals {
  # Mínimo para que Terraform del ambiente habilite el resto de APIs.
  environment_base_services = ["cloudresourcemanager.googleapis.com", "serviceusage.googleapis.com"]

  # serviceUsageConsumer: los providers cobran la cuota al proyecto del ambiente
  # (user_project_override), lo que exige serviceusage.services.use.
  plan_roles = [
    "roles/iam.securityReviewer",
    "roles/serviceusage.serviceUsageConsumer",
    "roles/viewer",
  ]

  # Permisos de la raíz del ambiente. projectIamAdmin es inevitable para
  # otorgar roles a las cargas; por eso tf-apply solo la impersonan operadores.
  apply_roles = [
    "roles/artifactregistry.admin",
    "roles/binaryauthorization.policyEditor",
    "roles/cloudsql.admin",
    "roles/compute.networkAdmin",
    "roles/compute.securityAdmin",
    "roles/container.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/monitoring.editor",
    "roles/pubsub.admin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/run.admin",
    "roles/secretmanager.admin",
    "roles/servicenetworking.networksAdmin",
    "roles/serviceusage.serviceUsageAdmin",
  ]

  # Lo que environments/delivery administra en el proyecto de gestión. Los
  # buckets se limitan por nombre con una condición IAM.
  delivery_apply_roles = [
    "roles/cloudbuild.builds.editor",
    "roles/cloudbuild.connectionAdmin",
    "roles/clouddeploy.admin",
  ]

  # Roles de proyecto (gestión) de cada identidad de entrega. Los permisos
  # sobre recursos concretos (repositorios, buckets, pipelines, servicios) los
  # conceden las raíces dueñas de esos recursos.
  # clouddeploy.viewer (solo lectura): `gcloud deploy releases create` espera la
  # operación de la release (clouddeploy.operations.get, a nivel de proyecto) antes
  # de crear el rollout; releaser sobre cada pipeline no cubre las operaciones.
  delivery_project_roles = {
    build_backend    = ["roles/logging.logWriter"]
    build_frontend   = ["roles/logging.logWriter"]
    release_promoter = ["roles/logging.logWriter", "roles/clouddeploy.viewer"]
    deploy_execution = ["roles/logging.logWriter", "roles/clouddeploy.jobRunner"]
  }

  environment_services = merge([
    for env, cfg in var.environments : {
      for svc in local.environment_base_services : "${env}/${svc}" => { project = cfg.project_id, service = svc }
    }
  ]...)

  plan_bindings = merge([
    for env, cfg in var.environments : {
      for role in local.plan_roles : "${env}/${role}" => { env = env, project = cfg.project_id, role = role }
    }
  ]...)

  apply_bindings = merge([
    for env, cfg in var.environments : {
      for role in local.apply_roles : "${env}/${role}" => { env = env, project = cfg.project_id, role = role }
    }
  ]...)

  # Como mucho un ambiente tiene entrega (validado en variables.tf).
  delivery_env = one([for env, cfg in var.environments : env if cfg.delivery])

  delivery_identities = local.delivery_env == null ? {} : var.delivery_account_ids

  delivery_project_bindings = merge([
    for key, roles in local.delivery_project_roles : {
      for role in roles : "${key}/${role}" => { key = key, role = role }
    } if contains(keys(local.delivery_identities), key)
  ]...)

  cloudbuild_agent  = "serviceAccount:service-${data.google_project.management.number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
  clouddeploy_agent = "serviceAccount:service-${data.google_project.management.number}@gcp-sa-clouddeploy.iam.gserviceaccount.com"
}

data "google_project" "management" {
  project_id = var.management_project_id
}

resource "google_project_service" "management" {
  for_each = toset(concat(
    [
      "billingbudgets.googleapis.com",
      "cloudresourcemanager.googleapis.com",
      "iam.googleapis.com",
      "iamcredentials.googleapis.com",
      "serviceusage.googleapis.com",
      "storage.googleapis.com",
    ],
    local.delivery_env == null ? [] : [
      "cloudbuild.googleapis.com",
      "clouddeploy.googleapis.com",
      "logging.googleapis.com",
      "secretmanager.googleapis.com",
    ],
  ))

  project            = var.management_project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_project_service" "environment" {
  for_each = local.environment_services

  project            = each.value.project
  service            = each.value.service
  disable_on_destroy = false
}

# --- Estado ---------------------------------------------------------------

resource "google_storage_bucket" "state" {
  for_each = var.environments

  project                     = var.management_project_id
  name                        = "${var.management_project_id}-tfstate-${each.key}"
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  labels = {
    app         = "sportapp"
    environment = each.key
    managed-by  = "terraform"
    purpose     = "terraform-state"
  }

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  lifecycle_rule {
    condition {
      num_newer_versions = var.state_versions_to_keep
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management]
}

# --- Cuentas de Terraform por ambiente --------------------------------------

resource "google_service_account" "plan" {
  for_each = var.environments

  project      = var.management_project_id
  account_id   = "tf-plan-${each.key}"
  display_name = "Terraform plan ${each.key} (solo operadores)"
  description  = "Planes manuales de lectura desde la estación del operador."
}

resource "google_service_account" "apply" {
  for_each = var.environments

  project      = var.management_project_id
  account_id   = "tf-apply-${each.key}"
  display_name = "Terraform apply ${each.key} (solo operadores)"
  description  = "Aplicación manual de infraestructura desde la estación del operador."
}

resource "google_project_iam_member" "plan" {
  for_each = local.plan_bindings

  project = each.value.project
  role    = each.value.role
  member  = google_service_account.plan[each.value.env].member
}

resource "google_project_iam_member" "apply" {
  for_each = local.apply_bindings

  project = each.value.project
  role    = each.value.role
  member  = google_service_account.apply[each.value.env].member
}

# plan también necesita escribir el lock del estado.
resource "google_storage_bucket_iam_member" "plan" {
  for_each = var.environments

  bucket = google_storage_bucket.state[each.key].name
  role   = "roles/storage.objectUser"
  member = google_service_account.plan[each.key].member
}

resource "google_storage_bucket_iam_member" "apply" {
  for_each = var.environments

  bucket = google_storage_bucket.state[each.key].name
  role   = "roles/storage.objectUser"
  member = google_service_account.apply[each.key].member
}

# Políticas autoritativas: solo los operadores humanos pueden obtener tokens de
# tf-plan y tf-apply. Cualquier otro binding a nivel de cuenta (Cloud Build,
# Cloud Deploy, GitHub o una cuenta de carga) se elimina en el siguiente apply.
# Sin roles/iam.serviceAccountUser: nadie adjunta estas cuentas a un recurso.
data "google_iam_policy" "terraform" {
  for_each = var.environments

  binding {
    role    = "roles/iam.serviceAccountTokenCreator"
    members = each.value.operators
  }
}

resource "google_service_account_iam_policy" "plan" {
  for_each = var.environments

  service_account_id = google_service_account.plan[each.key].name
  policy_data        = data.google_iam_policy.terraform[each.key].policy_data
}

resource "google_service_account_iam_policy" "apply" {
  for_each = var.environments

  service_account_id = google_service_account.apply[each.key].name
  policy_data        = data.google_iam_policy.terraform[each.key].policy_data
}

# --- Identidades de entrega (proyecto de gestión) ---------------------------
#
# cloud-build-backend / cloud-build-frontend: construyen y publican cada uno
#   solo en su repositorio de Artifact Registry y su bucket de evidencia.
# release-promoter: lee la evidencia y crea releases en pipelines existentes.
# cloud-deploy-execution: ejecuta los rollouts sobre los targets registrados.
# Ninguna tiene roles administrativos, impersona tf-apply ni aprueba rollouts.

resource "google_service_account" "delivery" {
  for_each = local.delivery_identities

  project      = var.management_project_id
  account_id   = each.value
  display_name = "SportApp ${local.delivery_env}: ${each.key}"
}

resource "google_project_iam_member" "delivery" {
  for_each = local.delivery_project_bindings

  project = var.management_project_id
  role    = each.value.role
  member  = google_service_account.delivery[each.value.key].member
}

# Quién puede usar cada identidad de entrega (políticas autoritativas):
# - tf-apply la adjunta a triggers y targets (actAs), sin obtener tokens;
# - release-promoter adjunta cloud-deploy-execution al crear una release;
# - los agentes de servicio de Cloud Build y Cloud Deploy obtienen sus tokens.
data "google_iam_policy" "delivery" {
  for_each = local.delivery_identities

  binding {
    role = "roles/iam.serviceAccountUser"
    members = concat(
      [google_service_account.apply[local.delivery_env].member],
      each.key == "deploy_execution" ? [google_service_account.delivery["release_promoter"].member] : [],
    )
  }

  binding {
    role    = "roles/iam.serviceAccountTokenCreator"
    members = [each.key == "deploy_execution" ? local.clouddeploy_agent : local.cloudbuild_agent]
  }
}

resource "google_service_account_iam_policy" "delivery" {
  for_each = local.delivery_identities

  service_account_id = google_service_account.delivery[each.key].name
  policy_data        = data.google_iam_policy.delivery[each.key].policy_data
}

# tf-apply administra en gestión los recursos de environments/delivery.
resource "google_project_iam_member" "delivery_apply" {
  for_each = local.delivery_env == null ? toset([]) : toset(local.delivery_apply_roles)

  project = var.management_project_id
  role    = each.value
  member  = google_service_account.apply[local.delivery_env].member
}

# Solo los buckets de entrega (prefijo fijo), nunca los de estado.
resource "google_project_iam_member" "delivery_apply_buckets" {
  count = local.delivery_env == null ? 0 : 1

  project = var.management_project_id
  role    = "roles/storage.admin"
  member  = google_service_account.apply[local.delivery_env].member

  condition {
    title       = "solo-buckets-de-entrega"
    description = "Buckets de evidencia y de Cloud Deploy creados por environments/delivery."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${var.management_project_id}-delivery-\")"
  }
}

# Al autorizar la GitHub App, el agente de Cloud Build guarda el token OAuth de la
# conexión en Secret Manager del proyecto de gestión. La consola concede este rol
# sola; la conexión creada con gcloud (scripts/sportapp-gcp.ps1) lo necesita aquí.
resource "google_project_iam_member" "cloudbuild_agent_connection_secrets" {
  count = local.delivery_env == null ? 0 : 1

  project = var.management_project_id
  role    = "roles/secretmanager.admin"
  member  = local.cloudbuild_agent
}

# environments/delivery lee del estado de producción los recursos destino.
resource "google_storage_bucket_iam_member" "delivery_reads_state" {
  count = local.delivery_env == null ? 0 : 1

  bucket = google_storage_bucket.state[local.delivery_env].name
  role   = "roles/storage.objectUser"
  member = google_service_account.apply[local.delivery_env].member
}

# --- Presupuestos -------------------------------------------------------------

data "google_project" "environment" {
  for_each = var.environments

  project_id = each.value.project_id
}

resource "google_billing_budget" "environment" {
  for_each = { for env, cfg in var.environments : env => cfg if var.billing_account != null && cfg.budget_amount > 0 }

  billing_account = var.billing_account
  display_name    = "sportapp-${each.key}"

  budget_filter {
    projects = ["projects/${data.google_project.environment[each.key].number}"]
  }

  amount {
    specified_amount {
      currency_code = var.budget_currency
      units         = tostring(each.value.budget_amount)
    }
  }

  # Montos absolutos convertidos a fracción del presupuesto, más el 100 %.
  dynamic "threshold_rules" {
    for_each = length(each.value.budget_alert_amounts) > 0 ? distinct(concat([for a in each.value.budget_alert_amounts : a / each.value.budget_amount], [1.0])) : [0.5, 0.9, 1.0]
    content {
      threshold_percent = threshold_rules.value
    }
  }

  # Pronóstico: avisa antes de superar el presupuesto.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  depends_on = [google_project_service.management]
}
