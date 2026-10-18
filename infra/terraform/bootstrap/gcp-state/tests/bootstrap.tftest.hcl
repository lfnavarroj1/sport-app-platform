# Pruebas de plan con proveedor simulado: no requieren credenciales ni crean
# recursos. Ejecutar desde bootstrap/gcp-state:
#   terraform init -backend=false
#   terraform test

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "111111111111"
    }
  }

  mock_resource "google_service_account" {
    defaults = {
      member = "serviceAccount:cuenta-simulada@sportapp-mgmt-test.iam.gserviceaccount.com"
      email  = "cuenta-simulada@sportapp-mgmt-test.iam.gserviceaccount.com"
      name   = "projects/sportapp-mgmt-test/serviceAccounts/cuenta-simulada@sportapp-mgmt-test.iam.gserviceaccount.com"
    }
  }

  # Las aserciones revisan los bindings declarados; el JSON final lo arma el proveedor.
  mock_data "google_iam_policy" {
    defaults = {
      policy_data = "{}"
    }
  }
}

# Correos distintos por cuenta: las políticas se comparan por miembro.
override_resource {
  target = google_service_account.apply["production"]
  values = {
    member = "serviceAccount:tf-apply-production@sportapp-mgmt-test.iam.gserviceaccount.com"
    email  = "tf-apply-production@sportapp-mgmt-test.iam.gserviceaccount.com"
    name   = "projects/sportapp-mgmt-test/serviceAccounts/tf-apply-production@sportapp-mgmt-test.iam.gserviceaccount.com"
  }
}

override_resource {
  target = google_service_account.plan["production"]
  values = {
    member = "serviceAccount:tf-plan-production@sportapp-mgmt-test.iam.gserviceaccount.com"
    email  = "tf-plan-production@sportapp-mgmt-test.iam.gserviceaccount.com"
    name   = "projects/sportapp-mgmt-test/serviceAccounts/tf-plan-production@sportapp-mgmt-test.iam.gserviceaccount.com"
  }
}

override_resource {
  target = google_service_account.delivery["release_promoter"]
  values = {
    member = "serviceAccount:release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com"
    email  = "release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com"
    name   = "projects/sportapp-mgmt-test/serviceAccounts/release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com"
  }
}

variables {
  management_project_id = "sportapp-mgmt-test"
  billing_account       = null

  environments = {
    production = {
      project_id = "sportapp-prod-test"
      operators  = ["user:operador@example.com", "group:operadores@example.com"]
      delivery   = true
    }
  }
}

run "terraform_solo_para_operadores" {
  # apply con proveedor simulado: no crea recursos; resuelve los valores calculados.
  command = apply

  # tf-apply y tf-plan: una única política autoritativa con los operadores.
  assert {
    condition = (
      length(data.google_iam_policy.terraform["production"].binding) == 1 &&
      one(data.google_iam_policy.terraform["production"].binding).role == "roles/iam.serviceAccountTokenCreator" &&
      toset(one(data.google_iam_policy.terraform["production"].binding).members) == toset(["user:operador@example.com", "group:operadores@example.com"])
    )
    error_message = "Solo los operadores humanos pueden obtener tokens de tf-plan y tf-apply; nadie puede adjuntarlas (actAs)."
  }

  assert {
    condition = (
      google_service_account_iam_policy.apply["production"].service_account_id == google_service_account.apply["production"].name &&
      google_service_account_iam_policy.plan["production"].service_account_id == google_service_account.plan["production"].name
    )
    error_message = "tf-plan y tf-apply tienen política IAM autoritativa."
  }

  # Ninguna identidad de entrega aparece en la política de Terraform.
  assert {
    condition = alltrue([
      for m in one(data.google_iam_policy.terraform["production"].binding).members :
      !startswith(m, "serviceAccount:") && !startswith(m, "principal") && m != "allUsers" && m != "allAuthenticatedUsers"
    ])
    error_message = "Cloud Build, Cloud Deploy, GitHub y las cuentas de carga no pueden impersonar Terraform."
  }

  assert {
    condition = alltrue([
      for role in local.apply_roles : !contains(["roles/owner", "roles/editor"], role)
    ])
    error_message = "tf-apply no recibe Owner ni Editor."
  }
}

run "identidades_de_entrega_separadas" {
  # apply con proveedor simulado: no crea recursos; resuelve los valores calculados.
  command = apply

  assert {
    condition = (
      google_service_account.delivery["build_backend"].account_id == "cloud-build-backend" &&
      google_service_account.delivery["build_frontend"].account_id == "cloud-build-frontend" &&
      google_service_account.delivery["release_promoter"].account_id == "release-promoter" &&
      google_service_account.delivery["deploy_execution"].account_id == "cloud-deploy-execution" &&
      length(google_service_account.delivery) == 4
    )
    error_message = "Cuatro identidades de entrega separadas, con los nombres parametrizados."
  }

  # Roles de proyecto: solo logs y, para la ejecución, el runner de Cloud Deploy.
  assert {
    condition = alltrue([
      for b in google_project_iam_member.delivery : contains(["roles/logging.logWriter", "roles/clouddeploy.jobRunner"], b.role)
    ])
    error_message = "Las identidades de entrega no reciben roles administrativos de proyecto."
  }

  assert {
    condition = (
      toset([for k, b in google_project_iam_member.delivery : b.role if startswith(k, "deploy_execution/")]) == toset(["roles/logging.logWriter", "roles/clouddeploy.jobRunner"]) &&
      length([for k, b in google_project_iam_member.delivery : b.role if b.role == "roles/clouddeploy.jobRunner" && !startswith(k, "deploy_execution/")]) == 0
    )
    error_message = "Solo cloud-deploy-execution ejecuta trabajos de Cloud Deploy."
  }

  # Nadie aprueba con estas identidades: approver no se concede en el bootstrap.
  assert {
    condition = alltrue([
      for b in google_project_iam_member.delivery : !strcontains(b.role, "approver") && !strcontains(b.role, "admin") && !strcontains(b.role, "owner") && !strcontains(b.role, "editor")
    ])
    error_message = "Las identidades de entrega no aprueban rollouts ni administran recursos."
  }

  # actAs: tf-apply adjunta las cuentas a triggers/targets; release-promoter solo
  # adjunta cloud-deploy-execution. Los tokens los obtienen los agentes de servicio.
  assert {
    condition = alltrue([
      for key, policy in data.google_iam_policy.delivery : (
        toset([for b in policy.binding : b.role]) == toset(["roles/iam.serviceAccountUser", "roles/iam.serviceAccountTokenCreator"]) &&
        alltrue([for b in policy.binding : alltrue([for m in b.members : !startswith(m, "principal") && !strcontains(m, "github")])])
      )
    ])
    error_message = "Las políticas de las identidades de entrega no admiten principals externos."
  }

  assert {
    condition = (
      toset(one([for b in data.google_iam_policy.delivery["deploy_execution"].binding : b.members if b.role == "roles/iam.serviceAccountTokenCreator"])) == toset(["serviceAccount:service-111111111111@gcp-sa-clouddeploy.iam.gserviceaccount.com"]) &&
      toset(one([for b in data.google_iam_policy.delivery["build_backend"].binding : b.members if b.role == "roles/iam.serviceAccountTokenCreator"])) == toset(["serviceAccount:service-111111111111@gcp-sa-cloudbuild.iam.gserviceaccount.com"])
    )
    error_message = "Solo el agente de Cloud Deploy obtiene tokens de la ejecución y solo el de Cloud Build los de las cuentas de build."
  }

  assert {
    condition = (
      toset(one([for b in data.google_iam_policy.delivery["deploy_execution"].binding : b.members if b.role == "roles/iam.serviceAccountUser"])) == toset([
        "serviceAccount:tf-apply-production@sportapp-mgmt-test.iam.gserviceaccount.com",
        "serviceAccount:release-promoter@sportapp-mgmt-test.iam.gserviceaccount.com",
      ]) &&
      alltrue([
        for key in ["build_backend", "build_frontend", "release_promoter"] :
        toset(one([for b in data.google_iam_policy.delivery[key].binding : b.members if b.role == "roles/iam.serviceAccountUser"])) == toset(["serviceAccount:tf-apply-production@sportapp-mgmt-test.iam.gserviceaccount.com"])
      ])
    )
    error_message = "Solo tf-apply (y release-promoter sobre la ejecución) pueden adjuntar identidades de entrega."
  }

  # tf-apply administra en gestión solo Cloud Build, Cloud Deploy y los buckets de entrega.
  assert {
    condition = (
      toset([for b in google_project_iam_member.delivery_apply : b.role]) == toset(["roles/cloudbuild.builds.editor", "roles/cloudbuild.connectionAdmin", "roles/clouddeploy.admin"]) &&
      strcontains(google_project_iam_member.delivery_apply_buckets[0].condition[0].expression, "sportapp-mgmt-test-delivery-")
    )
    error_message = "tf-apply solo administra Cloud Build, Cloud Deploy y buckets con prefijo de entrega en gestión."
  }
}

run "sin_entrega_no_hay_identidades" {
  command = plan

  variables {
    environments = {
      production = {
        project_id = "sportapp-prod-test"
        operators  = ["user:operador@example.com"]
      }
    }
  }

  assert {
    condition     = length(google_service_account.delivery) == 0 && length(google_project_iam_member.delivery_apply) == 0
    error_message = "Sin delivery = true no se crean identidades ni permisos de entrega."
  }
}

run "rechaza_operador_que_no_es_persona" {
  command = plan

  variables {
    environments = {
      production = {
        project_id = "sportapp-prod-test"
        operators  = ["principalSet://iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/github/attribute.repository/lfnavarroj1/sport-app-platform"]
      }
    }
  }

  expect_failures = [var.environments]
}

run "rechaza_cuenta_de_servicio_como_operador" {
  command = plan

  variables {
    environments = {
      production = {
        project_id = "sportapp-prod-test"
        operators  = ["serviceAccount:cloud-build-backend@sportapp-mgmt-test.iam.gserviceaccount.com"]
      }
    }
  }

  expect_failures = [var.environments]
}

run "rechaza_nombre_tf_para_entrega" {
  command = plan

  variables {
    delivery_account_ids = {
      build_backend    = "tf-apply-production"
      build_frontend   = "cloud-build-frontend"
      release_promoter = "release-promoter"
      deploy_execution = "cloud-deploy-execution"
    }
  }

  expect_failures = [var.delivery_account_ids]
}
