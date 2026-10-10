# Fundación que debe existir antes de las raíces de environments/:
# - un bucket de estado versionado por ambiente en el proyecto de gestión;
# - Workload Identity Federation para GitHub Actions (sin llaves JSON);
# - por ambiente, una cuenta tf-plan (lectura) y una tf-apply (cambios);
# - presupuestos con alertas por proyecto (no limitan el gasto por sí solos).

locals {
  # Mínimo para que Terraform del ambiente habilite el resto de APIs.
  environment_base_services = ["cloudresourcemanager.googleapis.com", "serviceusage.googleapis.com"]

  plan_roles = [
    "roles/iam.securityReviewer",
    "roles/viewer",
  ]

  # Permisos de la raíz del ambiente. projectIamAdmin es inevitable para
  # otorgar roles a las cargas; por eso tf-apply solo se usa desde un GitHub
  # Environment protegido o por operadores explícitos.
  apply_roles = [
    "roles/artifactregistry.admin",
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

  operator_bindings = merge([
    for env, cfg in var.environments : {
      for member in cfg.operators : "${env}/${member}" => { env = env, member = member }
    }
  ]...)

  delivery_environments = { for env, cfg in var.environments : env => cfg if cfg.component_delivery }

  delivery_bindings = merge([
    for env in keys(local.delivery_environments) : {
      for repo in var.component_repositories : "${env}/${repo}" => { env = env, repo = repo }
    }
  ]...)
}

resource "google_project_service" "management" {
  for_each = toset([
    "billingbudgets.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ])

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

# --- Identidad de GitHub Actions --------------------------------------------

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.management_project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  description               = "OIDC de GitHub Actions para Terraform de SportApp"

  depends_on = [google_project_service.management]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.management_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "sport-app-platform"
  display_name                       = "sport-app-platform"

  attribute_mapping = {
    "google.subject"             = "assertion.sub"
    "attribute.repository"       = "assertion.repository"
    "attribute.repository_owner" = "assertion.repository_owner"
    "attribute.ref"              = "assertion.ref"
  }

  # Solo la plataforma y los componentes declarados pueden intercambiar tokens;
  # cada cuenta restringe además qué repositorio y ambiente la usa.
  attribute_condition = "assertion.repository in ${jsonencode(concat([var.github_repository], var.component_repositories))}"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# --- Cuentas de Terraform por ambiente --------------------------------------

resource "google_service_account" "plan" {
  for_each = var.environments

  project      = var.management_project_id
  account_id   = "tf-plan-${each.key}"
  display_name = "Terraform plan ${each.key}"
}

resource "google_service_account" "apply" {
  for_each = var.environments

  project      = var.management_project_id
  account_id   = "tf-apply-${each.key}"
  display_name = "Terraform apply ${each.key}"
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

# Cualquier job del repositorio (incluidos PR) puede generar un plan.
resource "google_service_account_iam_member" "plan_github" {
  for_each = var.environments

  service_account_id = google_service_account.plan[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# Solo un job que declare `environment: <ambiente>` (con sus reglas de
# aprobación en GitHub) puede aplicar.
resource "google_service_account_iam_member" "apply_github" {
  for_each = var.environments

  service_account_id = google_service_account.apply[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/subject/repo:${var.github_repository}:environment:${each.key}"
}

# Publicación de imágenes desde backend y frontend. La cuenta no tiene roles
# en el proyecto: la raíz del ambiente le concede escritura solo en su
# Artifact Registry mediante artifact_registry_writers.
resource "google_service_account" "delivery" {
  for_each = local.delivery_environments

  project      = var.management_project_id
  account_id   = "ci-delivery-${each.key}"
  display_name = "Publicación de imágenes ${each.key}"
}

resource "google_service_account_iam_member" "delivery_github" {
  for_each = local.delivery_bindings

  service_account_id = google_service_account.delivery[each.value.env].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/subject/repo:${each.value.repo}:environment:${each.value.env}"
}

# Personas que operan Terraform desde su equipo por impersonación.
resource "google_service_account_iam_member" "operators_plan" {
  for_each = local.operator_bindings

  service_account_id = google_service_account.plan[each.value.env].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = each.value.member
}

resource "google_service_account_iam_member" "operators_apply" {
  for_each = local.operator_bindings

  service_account_id = google_service_account.apply[each.value.env].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = each.value.member
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
