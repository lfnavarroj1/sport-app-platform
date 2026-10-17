# Pruebas de plan con proveedor simulado: no requieren credenciales ni crean
# recursos. Ejecutar desde modules/gcp/pubsub-consumer:
#   terraform init -backend=false
#   terraform test

mock_provider "google" {}

variables {
  project_id        = "sportapp-test"
  project_number    = "123456789012"
  topic             = "projects/sportapp-test/topics/sportapp.usuarios.v1"
  subscription      = "sportapp.afiliacion.alta-gratuita.v1"
  dead_letter_topic = "sportapp.afiliacion.alta-gratuita.dlq"
  filter            = "attributes.event_type = \"usuario.registrado.v1\""

  settings = {
    message_retention_duration = "604800s"
    ack_deadline_seconds       = 60
    max_delivery_attempts      = 10
    minimum_backoff            = "10s"
    maximum_backoff            = "600s"
  }

  subscriber_members = { affiliation-consumer = "serviceAccount:gke-affiliation-consumer@sportapp-test.iam.gserviceaccount.com" }
}

# HU001 (ADR-024, R-19): alta gratuita sobre el tópico de Usuarios.
run "alta_gratuita" {
  command = plan

  assert {
    condition = (
      google_pubsub_subscription.consumer.name == "sportapp.afiliacion.alta-gratuita.v1" &&
      google_pubsub_subscription.consumer.topic == "projects/sportapp-test/topics/sportapp.usuarios.v1"
    )
    error_message = "La suscripción sportapp.afiliacion.alta-gratuita.v1 consume el tópico de Usuarios."
  }

  assert {
    condition     = google_pubsub_subscription.consumer.filter == "attributes.event_type = \"usuario.registrado.v1\""
    error_message = "Solo se entrega usuario.registrado.v1 (R-19)."
  }

  assert {
    condition = (
      google_pubsub_subscription.consumer.enable_message_ordering &&
      google_pubsub_subscription.consumer.dead_letter_policy[0].max_delivery_attempts == 10 &&
      google_pubsub_subscription.consumer.retry_policy[0].minimum_backoff == "10s" &&
      google_pubsub_subscription.consumer.retry_policy[0].maximum_backoff == "600s" &&
      google_pubsub_subscription.consumer.expiration_policy[0].ttl == ""
    )
    error_message = "Orden por user_id, 10 entregas, espera de 10 a 600 s y sin expiración (ADR-024)."
  }

  assert {
    condition = (
      google_pubsub_topic.dead_letter.name == "sportapp.afiliacion.alta-gratuita.dlq" &&
      google_pubsub_subscription.dead_letter_ops.name == "sportapp.afiliacion.alta-gratuita.dlq.ops"
    )
    error_message = "DLQ sportapp.afiliacion.alta-gratuita.dlq y su suscripción operativa .dlq.ops."
  }

  assert {
    condition = (
      keys(google_pubsub_subscription_iam_member.subscribers) == ["affiliation-consumer"] &&
      google_pubsub_subscription_iam_member.subscribers["affiliation-consumer"].role == "roles/pubsub.subscriber" &&
      google_pubsub_subscription_iam_member.subscribers["affiliation-consumer"].subscription == "sportapp.afiliacion.alta-gratuita.v1"
    )
    error_message = "Solo el consumidor del alta gratuita consume, y solo de su suscripción."
  }

  assert {
    condition = (
      google_pubsub_topic_iam_member.dead_letter_agent.topic == "sportapp.afiliacion.alta-gratuita.dlq" &&
      google_pubsub_subscription_iam_member.dead_letter_agent.subscription == "sportapp.afiliacion.alta-gratuita.v1"
    )
    error_message = "El agente de Pub/Sub puede reenviar a la DLQ."
  }
}

run "sin_filtro" {
  command = plan

  variables {
    filter = null
  }

  assert {
    condition     = google_pubsub_subscription.consumer.filter == null
    error_message = "Sin filtro se entregan todos los mensajes del tópico."
  }
}
