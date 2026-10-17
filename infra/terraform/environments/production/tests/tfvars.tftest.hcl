# Comprueba, sin credenciales, que terraform.tfvars produce un plan válido
# y respeta las reglas del ambiente. Ejecutar: terraform init -backend=false && terraform test

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
}

# random no se simula: el mock aún no admite recursos efímeros y el proveedor
# real no tiene efectos externos.

variables {
  project_id                  = "sportapp-test"
  impersonate_service_account = null
}

run "terraform_tfvars_es_valido" {
  command = plan

  # HU010 (CMP-003): proyector de entrenamientos con 10 entregas y espera de 10 a 600 s.
  assert {
    condition = (
      output.pubsub["entrenamientos"].projector_subscription == "proyector-entrenamientos-v1" &&
      output.pubsub["entrenamientos"].dead_letter_topic == "sportapp.entrenamientos.proyeccion.dlq" &&
      var.pubsub.max_delivery_attempts == 10 &&
      var.pubsub.minimum_backoff == "10s" &&
      var.pubsub.maximum_backoff == "600s"
    )
    error_message = "Producción debe crear la suscripción y la DLQ de entrenamientos con 10 entregas y espera de 10 a 600 s."
  }

  # HU001 (ADR-024, CMP-001): mensajería de Usuarios y Afiliación y versión de políticas de la web.
  assert {
    condition = (
      output.pubsub["usuarios"].projector_subscription == "proyector-usuarios-v1" &&
      output.pubsub["usuarios"].dead_letter_topic == "sportapp.usuarios.proyeccion.dlq" &&
      output.affiliation_pubsub.topic == "sportapp.afiliacion.v1" &&
      output.affiliation_pubsub.free_plan_subscription == "sportapp.afiliacion.alta-gratuita.v1" &&
      output.affiliation_pubsub.free_plan_dead_letter_topic == "sportapp.afiliacion.alta-gratuita.dlq" &&
      var.cloud_run_env["web"].REGISTRATION_POLICIES_VERSION == "sportapp-c108-c108plus.v1"
    )
    error_message = "Producción crea la mensajería de HU001 y publica la versión de políticas aprobada para la web."
  }
}
