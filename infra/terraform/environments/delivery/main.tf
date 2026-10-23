# Plano de entrega de producción en el proyecto de gestión:
# - conexión de Cloud Build con GitHub originada en GCP (GitHub App) y los
#   repositorios que GCP lee; GitHub no recibe identidad GCP;
# - triggers por tag que construyen y publican por digest con cuentas propias;
# - evidencia de releases (backend-release.json, frontend-release.json);
# - promotor manual (cloudbuild.promote.yaml) con release-promoter;
# - pipelines y targets de Cloud Deploy, todos con aprobación humana.
#
# Terraform administra estos recursos; las releases, imágenes, Deployments,
# Jobs y revisiones los administra Cloud Deploy. Se aplica desde la estación del
# operador después de environments/production y production-workloads.

data "terraform_remote_state" "production" {
  backend = "gcs"
  config = {
    bucket                      = var.state_bucket
    prefix                      = "sportapp/production"
    impersonate_service_account = var.impersonate_service_account
  }
}

locals {
  production = data.terraform_remote_state.production.outputs
  allowlist  = jsondecode(file("${path.module}/../../../../deploy/clouddeploy/allowlist.json"))

  ids = var.delivery_identities

  # <región>-docker.pkg.dev/<proyecto>/<repositorio>
  ar_backend  = local.production.artifact_registry_urls.backend
  ar_frontend = local.production.artifact_registry_urls.frontend
  ar_location = split("-docker.pkg.dev/", local.ar_backend)[0]
  ar_project  = split("/", local.ar_backend)[1]

  evidence_buckets = {
    backend  = "${var.management_project_id}-delivery-evidence-backend"
    frontend = "${var.management_project_id}-delivery-evidence-frontend"
  }
  source_bucket    = "${var.management_project_id}-delivery-clouddeploy-source"
  artifacts_bucket = "${var.management_project_id}-delivery-clouddeploy-artifacts"

  build_identity = { backend = local.ids.build_backend, frontend = local.ids.build_frontend }

  # Servicio de Cloud Run -> pipeline y target (allowlist exacta).
  cloud_run_targets = {
    bff-web    = { pipeline = "bff-web", target = "production-bff-web", template = "cloudrun/bff-web" }
    bff-mobile = { pipeline = "bff-mobile", target = "production-bff-mobile", template = "cloudrun/bff-mobile" }
    web        = { pipeline = "frontend-web", target = "production-web", template = "cloudrun/web" }
  }

  # Solo los servicios que Terraform ya creó (primera release, sección 13).
  cloud_run_deployed = { for svc, t in local.cloud_run_targets : svc => t if contains(keys(local.production.cloud_run_deploy_config), svc) }

  # Parámetros del target: la misma configuración que administra Terraform.
  cloud_run_params = {
    for svc, t in local.cloud_run_deployed : svc => merge(
      {
        service_account = local.production.cloud_run_deploy_config[svc].service_account
        min_instances   = tostring(local.production.cloud_run_deploy_config[svc].min_instances)
        max_instances   = tostring(local.production.cloud_run_deploy_config[svc].max_instances)
        concurrency     = tostring(local.production.cloud_run_deploy_config[svc].concurrency)
        timeout_seconds = tostring(local.production.cloud_run_deploy_config[svc].timeout_seconds)
        cpu             = local.production.cloud_run_deploy_config[svc].cpu
        memory          = local.production.cloud_run_deploy_config[svc].memory
      },
      { for k, v in local.production.cloud_run_deploy_config[svc].env : "env_${k}" => v },
    )
  }

  # Red VPC escrita en la plantilla (anotación network-interfaces). No viaja como
  # parámetro porque Skaffold no admite comillas en --set; se valida contra Terraform.
  cloud_run_template_network = {
    for svc, t in local.cloud_run_targets : svc => try(
      jsondecode(regex("run\\.googleapis\\.com/network-interfaces: '([^']+)'", file("${path.module}/../../../../deploy/clouddeploy/${t.template}/service.yaml"))[0]),
      null,
    )
  }

  # Parámetros que espera cada plantilla (comentarios from-param).
  cloud_run_template_params = {
    for svc, t in local.cloud_run_targets : svc => toset(flatten(regexall("from-param: \\$\\{([A-Za-z0-9_]+)\\}", file("${path.module}/../../../../deploy/clouddeploy/${t.template}/service.yaml"))))
  }

  gke_targets = {
    production-gke-migrations = { profile = "migrations", description = "Jobs de migración de la release; la verificación espera Complete." }
    production-gke            = { profile = "workloads", description = "Deployments del backend; se promueve solo después de las migraciones." }
  }

  # Orden explícito (un mapa se recorre alfabéticamente): migraciones primero.
  backend_stages = ["production-gke-migrations", "production-gke"]

  pipelines = merge(
    { backend-gke = { stages = [for t in local.backend_stages : { target = t, profiles = [local.gke_targets[t].profile] }], description = "Backend en GKE: migraciones y luego Deployments." } },
    { for svc, t in local.cloud_run_deployed : t.pipeline => { stages = [{ target = t.target, profiles = [] }], description = "Cloud Run ${svc}." } },
  )

  # Promotor: valores fijos que recibe scripts/promote_release.py.
  promote_substitutions = {
    _COMPONENT                   = ""
    _VERSION                     = ""
    _BACKEND_VERSION             = ""
    _RELEASE_SUFFIX              = ""
    _DELIVERY_PROJECT            = var.management_project_id
    _REGION                      = var.region
    _EVIDENCE_BUCKET_BACKEND     = local.evidence_buckets.backend
    _EVIDENCE_BUCKET_FRONTEND    = local.evidence_buckets.frontend
    _SOURCE_BUCKET               = local.source_bucket
    _AR_BACKEND                  = local.ar_backend
    _AR_FRONTEND                 = local.ar_frontend
    _GKE_CLUSTER                 = local.production.gke.name
    _GKE_LOCATION                = local.production.gke.location
    _GKE_PROJECT                 = local.ar_project
    _NAMESPACE                   = local.production.gke.namespace
    _RUN_PROJECT                 = local.ar_project
    _RUN_REGION                  = local.ar_location
    _DEPLOY_TOOLS_IMAGE          = var.deploy_tools_image
    _RUN_VERIFY_IMAGE            = var.run_verify_image
    _PROMOTER_IMAGE              = var.promoter_image
    _BACKEND_REPOSITORY_RESOURCE = var.github_connection_ready ? google_cloudbuildv2_repository.this["backend"].id : ""
  }
}

# Las identidades declaradas aquí deben ser las que producción autorizó.
check "identidades_coherentes" {
  assert {
    condition     = local.production.delivery_identities == var.delivery_identities
    error_message = "delivery_identities no coincide con la salida de environments/production: aplique primero producción con las mismas identidades."
  }
}

# --- Evidencia de releases ---------------------------------------------------
#
# Un bucket por componente: cada cuenta de Cloud Build solo crea objetos en el
# suyo (sin sobrescribir ni borrar) y release-promoter solo lee ambos.

resource "google_storage_bucket" "evidence" {
  for_each = local.evidence_buckets

  project                     = var.management_project_id
  name                        = each.value
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  labels = {
    app       = "sportapp"
    component = each.key
    purpose   = "release-evidence"
  }

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 2592000
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = var.evidence_retention_days
      with_state                 = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  dynamic "encryption" {
    for_each = var.evidence_kms_key == null ? [] : [var.evidence_kms_key]
    content {
      default_kms_key_name = encryption.value
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# objectCreator: crear, nunca sobrescribir ni borrar una evidencia existente.
resource "google_storage_bucket_iam_member" "evidence_writer" {
  for_each = local.evidence_buckets

  bucket = google_storage_bucket.evidence[each.key].name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${local.build_identity[each.key]}"
}

# Lectura de su propio bucket para la cuenta de build: Cloud Build consulta el
# bucket antes de subir los artifacts (storage.buckets.get) y `gcloud storage cp`
# consulta el objeto de destino (storage.objects.get). Ninguno permite
# sobrescribir ni borrar, así que la evidencia sigue siendo inmutable.
resource "google_storage_bucket_iam_member" "evidence_writer_read" {
  for_each = {
    for pair in setproduct(keys(local.evidence_buckets), ["roles/storage.legacyBucketReader", "roles/storage.objectViewer"]) :
    "${pair[0]}/${pair[1]}" => { component = pair[0], role = pair[1] }
  }

  bucket = google_storage_bucket.evidence[each.value.component].name
  role   = each.value.role
  member = "serviceAccount:${local.build_identity[each.value.component]}"
}

resource "google_storage_bucket_iam_member" "evidence_reader" {
  for_each = local.evidence_buckets

  bucket = google_storage_bucket.evidence[each.key].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${local.ids.release_promoter}"
}

# --- Buckets de Cloud Deploy -------------------------------------------------

resource "google_storage_bucket" "clouddeploy" {
  for_each = { source = local.source_bucket, artifacts = local.artifacts_bucket }

  project                     = var.management_project_id
  name                        = each.value
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  labels = {
    app     = "sportapp"
    purpose = "clouddeploy-${each.key}"
  }

  lifecycle_rule {
    condition {
      age = 180
    }
    action {
      type = "Delete"
    }
  }
}

# El promotor sube la fuente de cada release; la ejecución la lee para renderizar.
resource "google_storage_bucket_iam_member" "source_promoter" {
  for_each = toset(["roles/storage.objectCreator", "roles/storage.objectViewer"])

  bucket = google_storage_bucket.clouddeploy["source"].name
  role   = each.value
  member = "serviceAccount:${local.ids.release_promoter}"
}

resource "google_storage_bucket_iam_member" "source_execution" {
  bucket = google_storage_bucket.clouddeploy["source"].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${local.ids.deploy_execution}"
}

resource "google_storage_bucket_iam_member" "artifacts_execution" {
  bucket = google_storage_bucket.clouddeploy["artifacts"].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.ids.deploy_execution}"
}

# `gcloud deploy releases create` (promotor) y el render y despliegue de Cloud
# Deploy (ejecución) consultan el bucket antes de usarlo (storage.buckets.get),
# que los roles de objetos no incluyen. legacyBucketReader solo añade esa
# consulta y el listado.
resource "google_storage_bucket_iam_member" "clouddeploy_bucket_reader" {
  for_each = {
    "source/promoter"     = { bucket = "source", member = local.ids.release_promoter }
    "source/execution"    = { bucket = "source", member = local.ids.deploy_execution }
    "artifacts/execution" = { bucket = "artifacts", member = local.ids.deploy_execution }
  }

  bucket = google_storage_bucket.clouddeploy[each.value.bucket].name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${each.value.member}"
}

# --- Conexión de Cloud Build con GitHub (originada en GCP) -------------------
#
# La API exige github_config al crear la conexión y el provider omite el bloque
# vacío, así que Terraform no puede crear una conexión pendiente sin un PAT. La
# crea el operador con `gcloud builds connections create github github` y se
# importa (scripts/sportapp-gcp.ps1 lo hace solo; a mano: sección 13.2 de
# docs/preparacion-terraform-gcp.md). Después el operador completa una vez la
# instalación de la GitHub App en la consola de GCP: ese paso escribe
# github_config (instalación y token OAuth, guardado por Cloud Build en Secret
# Manager), que por eso Terraform no reconcilia. Ningún PAT ni secreto de
# GitHub pasa por Terraform.

resource "google_cloudbuildv2_connection" "github" {
  project  = var.management_project_id
  location = var.region
  name     = "github"

  github_config {}

  lifecycle {
    ignore_changes = [github_config]
  }
}

resource "google_cloudbuildv2_repository" "this" {
  for_each = var.github_connection_ready ? var.github_repositories : {}

  project           = var.management_project_id
  location          = var.region
  parent_connection = google_cloudbuildv2_connection.github.name
  name              = element(split("/", each.value), 1)
  remote_uri        = "https://github.com/${each.value}.git"
}

# Leer el código: cada cuenta de build y el promotor (que lee la plataforma y,
# para el backend, deploy/k8s/base en el commit de la release).
resource "google_cloudbuildv2_connection_iam_member" "read_token" {
  for_each = {
    build-backend    = local.ids.build_backend
    build-frontend   = local.ids.build_frontend
    release-promoter = local.ids.release_promoter
  }

  project  = var.management_project_id
  location = var.region
  name     = google_cloudbuildv2_connection.github.name
  role     = "roles/cloudbuild.readTokenAccessor"
  member   = "serviceAccount:${each.value}"
}

# --- Triggers de release (tag SemVer) ----------------------------------------
#
# La cuenta la fija el trigger: los repositorios no declaran serviceAccount y
# las cuentas de build no pueden adjuntar otra (sin actAs). Las sustituciones
# son exactamente las que declara cada cloudbuild.release.yaml.

resource "google_cloudbuild_trigger" "release" {
  for_each = var.github_connection_ready ? { backend = "release-backend", frontend = "release-frontend" } : {}

  project         = var.management_project_id
  location        = var.region
  name            = each.value
  description     = "Tag SemVer de ${var.github_repositories[each.key]}: prueba, construye una vez, publica por digest y escribe la evidencia. No despliega."
  service_account = "projects/${var.management_project_id}/serviceAccounts/${local.build_identity[each.key]}"
  filename        = "cloudbuild.release.yaml"
  disabled        = !var.release_triggers_enabled

  repository_event_config {
    repository = google_cloudbuildv2_repository.this[each.key].id
    push {
      tag = var.release_tag_pattern
    }
  }

  substitutions = each.key == "backend" ? {
    _AR_LOCATION    = local.ar_location
    _AR_PROJECT     = local.ar_project
    _AR_REPOSITORY  = "sportapp-backend"
    _RELEASE_BUCKET = google_storage_bucket.evidence["backend"].name
    } : {
    _REGISTRY       = "${local.ar_location}-docker.pkg.dev/${local.ar_project}"
    _REPOSITORY     = "sportapp-frontend"
    _RELEASE_BUCKET = google_storage_bucket.evidence["frontend"].name
  }
}

# Promotor: trigger manual interno (consola de GCP o gcloud del operador),
# nunca invocado desde GitHub. Construye desde main de sport-app-platform.
resource "google_cloudbuild_trigger" "promote" {
  count = var.github_connection_ready ? 1 : 0

  project         = var.management_project_id
  location        = var.region
  name            = "promote-release"
  description     = "Valida backend-release.json o frontend-release.json y crea releases de Cloud Deploy pendientes de aprobación. No aprueba ni ejecuta Terraform."
  service_account = "projects/${var.management_project_id}/serviceAccounts/${local.ids.release_promoter}"

  source_to_build {
    repository = google_cloudbuildv2_repository.this["platform"].id
    ref        = "refs/heads/main"
    repo_type  = "GITHUB"
  }

  git_file_source {
    path       = "cloudbuild.promote.yaml"
    repository = google_cloudbuildv2_repository.this["platform"].id
    revision   = "refs/heads/main"
    repo_type  = "GITHUB"
  }

  substitutions = local.promote_substitutions
}

# --- Cloud Deploy ------------------------------------------------------------

resource "google_clouddeploy_target" "gke" {
  for_each = local.gke_targets

  project          = var.management_project_id
  location         = var.region
  name             = each.key
  description      = each.value.description
  require_approval = true

  gke {
    cluster      = local.production.gke.cluster_id
    dns_endpoint = true
  }

  execution_configs {
    usages           = ["RENDER", "DEPLOY", "VERIFY"]
    service_account  = local.ids.deploy_execution
    artifact_storage = "gs://${google_storage_bucket.clouddeploy["artifacts"].name}/${each.key}"
  }
}

resource "google_clouddeploy_target" "run" {
  for_each = local.cloud_run_deployed

  project          = var.management_project_id
  location         = var.region
  name             = each.value.target
  description      = "Servicio Cloud Run ${each.key}; un rollout solo cambia la imagen."
  require_approval = true

  run {
    location = local.production.cloud_run_deploy_config[each.key].location
  }

  deploy_parameters = local.cloud_run_params[each.key]

  execution_configs {
    usages           = ["RENDER", "DEPLOY", "VERIFY"]
    service_account  = local.ids.deploy_execution
    artifact_storage = "gs://${google_storage_bucket.clouddeploy["artifacts"].name}/${each.value.target}"
  }

  lifecycle {
    precondition {
      condition     = length(local.production.cloud_run_deploy_config[each.key].secret_env) == 0
      error_message = "La plantilla de Cloud Deploy no declara secretos: agréguelos a deploy/clouddeploy antes de usar cloud_run_secret_env."
    }
    precondition {
      condition     = toset(keys(local.cloud_run_params[each.key])) == local.cloud_run_template_params[each.key]
      error_message = "Los parámetros del target no coinciden con los from-param de la plantilla de Cloud Run: actualice deploy/clouddeploy para que un rollout no cambie la configuración de Terraform."
    }
    precondition {
      condition = local.cloud_run_template_network[each.key] == (
        local.production.cloud_run_deploy_config[each.key].vpc_subnetwork == null ? null : [{
          network    = local.production.cloud_run_deploy_config[each.key].vpc_network
          subnetwork = local.production.cloud_run_deploy_config[each.key].vpc_subnetwork
        }]
      )
      error_message = "La anotación network-interfaces de la plantilla de Cloud Run no coincide con la red VPC de Terraform: actualice deploy/clouddeploy."
    }
  }
}

resource "google_clouddeploy_delivery_pipeline" "this" {
  for_each = local.pipelines

  project     = var.management_project_id
  location    = var.region
  name        = each.key
  description = each.value.description

  serial_pipeline {
    dynamic "stages" {
      for_each = each.value.stages
      content {
        target_id = stages.value.target
        profiles  = stages.value.profiles

        strategy {
          standard {
            verify = true
          }
        }
      }
    }
  }

  depends_on = [google_clouddeploy_target.gke, google_clouddeploy_target.run]
}

# El promotor solo crea releases en pipelines existentes (releaser no aprueba
# ni cambia pipelines o targets).
resource "google_clouddeploy_delivery_pipeline_iam_member" "releaser" {
  for_each = local.pipelines

  project  = var.management_project_id
  location = var.region
  name     = google_clouddeploy_delivery_pipeline.this[each.key].name
  role     = "roles/clouddeploy.releaser"
  member   = "serviceAccount:${local.ids.release_promoter}"
}

# Solo personas o grupos aprueban.
resource "google_clouddeploy_delivery_pipeline_iam_member" "approver" {
  for_each = { for pair in setproduct(keys(local.pipelines), var.approvers) : "${pair[0]}/${pair[1]}" => { pipeline = pair[0], member = pair[1] } }

  project  = var.management_project_id
  location = var.region
  name     = google_clouddeploy_delivery_pipeline.this[each.value.pipeline].name
  role     = "roles/clouddeploy.approver"
  member   = each.value.member
}
