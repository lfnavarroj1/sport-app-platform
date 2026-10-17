# Pruebas de plan con proveedor simulado: no requieren credenciales ni crean
# recursos. Ejecutar desde modules/gcp/pubsub:
#   terraform init -backend=false
#   terraform test

mock_provider "google" {}

variables {
  project_id     = "sportapp-test"
  project_number = "123456789012"
  domain         = "entrenamientos"

  settings = {
    message_retention_duration = "604800s"
    ack_deadline_seconds       = 60
    max_delivery_attempts      = 10
    minimum_backoff            = "10s"
    maximum_backoff            = "600s"
  }

  publisher_members  = { training-outbox = "serviceAccount:gke-training-outbox@sportapp-test.iam.gserviceaccount.com" }
  subscriber_members = { training-projector = "serviceAccount:gke-training-projector@sportapp-test.iam.gserviceaccount.com" }
}

# HU010 (CMP-003): recursos que consumen training-management-outbox-publisher y
# training-management-read-projector.
run "entrenamientos_con_nombres_de_contrato" {
  command = plan

  variables {
    names = {
      projector_subscription = "proyector-entrenamientos-v1"
      dead_letter_topic      = "sportapp.entrenamientos.proyeccion.dlq"
    }
  }

  assert {
    condition     = google_pubsub_topic.events.name == "sportapp.entrenamientos.v1"
    error_message = "El tópico del dominio es sportapp.entrenamientos.v1."
  }

  assert {
    condition     = google_pubsub_subscription.projector.name == "proyector-entrenamientos-v1"
    error_message = "La suscripción del proyector es proyector-entrenamientos-v1."
  }

  assert {
    condition     = google_pubsub_topic.dead_letter.name == "sportapp.entrenamientos.proyeccion.dlq"
    error_message = "La DLQ del proyector es sportapp.entrenamientos.proyeccion.dlq."
  }

  assert {
    condition     = google_pubsub_subscription.dead_letter_ops.name == "sportapp.entrenamientos.proyeccion.dlq.ops"
    error_message = "La suscripción operativa de la DLQ es <dlq>.ops."
  }

  assert {
    condition     = google_pubsub_subscription.projector.enable_message_ordering
    error_message = "La suscripción del proyector entrega en orden por clave (plan_id)."
  }

  assert {
    condition     = google_pubsub_subscription.projector.dead_letter_policy[0].max_delivery_attempts == 10
    error_message = "El proyector tiene un máximo de 10 entregas antes de la DLQ."
  }

  assert {
    condition = (
      google_pubsub_subscription.projector.retry_policy[0].minimum_backoff == "10s" &&
      google_pubsub_subscription.projector.retry_policy[0].maximum_backoff == "600s"
    )
    error_message = "La espera entre reintentos va de 10 a 600 segundos."
  }

  assert {
    condition     = google_pubsub_subscription.projector.expiration_policy[0].ttl == ""
    error_message = "La suscripción del proyector no expira por inactividad."
  }

  assert {
    condition = (
      keys(google_pubsub_topic_iam_member.publishers) == ["training-outbox"] &&
      google_pubsub_topic_iam_member.publishers["training-outbox"].role == "roles/pubsub.publisher" &&
      google_pubsub_topic_iam_member.publishers["training-outbox"].topic == "sportapp.entrenamientos.v1"
    )
    error_message = "Solo el publicador outbox publica, y solo en el tópico del dominio."
  }

  assert {
    condition = (
      keys(google_pubsub_subscription_iam_member.subscribers) == ["training-projector"] &&
      google_pubsub_subscription_iam_member.subscribers["training-projector"].role == "roles/pubsub.subscriber" &&
      google_pubsub_subscription_iam_member.subscribers["training-projector"].subscription == "proyector-entrenamientos-v1"
    )
    error_message = "Solo el proyector consume, y solo de su suscripción."
  }

  assert {
    condition = (
      google_pubsub_topic_iam_member.dead_letter_agent.topic == "sportapp.entrenamientos.proyeccion.dlq" &&
      google_pubsub_subscription_iam_member.dead_letter_agent.subscription == "proyector-entrenamientos-v1" &&
      google_pubsub_topic_iam_member.dead_letter_agent.member == "serviceAccount:service-123456789012@gcp-sa-pubsub.iam.gserviceaccount.com"
    )
    error_message = "El agente de Pub/Sub puede reenviar a la DLQ desde la suscripción del proyector."
  }
}

# HU001 (CMP-001): el proyector de usuarios tiene 5 entregas antes de la DLQ.
run "usuarios_con_entregas_del_perfil" {
  command = plan

  variables {
    domain                = "usuarios"
    max_delivery_attempts = 5
    names = {
      projector_subscription = "proyector-usuarios-v1"
      dead_letter_topic      = "sportapp.usuarios.proyeccion.dlq"
    }
  }

  assert {
    condition = (
      google_pubsub_subscription.projector.name == "proyector-usuarios-v1" &&
      google_pubsub_subscription.projector.dead_letter_policy[0].max_delivery_attempts == 5 &&
      google_pubsub_subscription.dead_letter_ops.name == "sportapp.usuarios.proyeccion.dlq.ops"
    )
    error_message = "Usuarios usa proyector-usuarios-v1, 5 entregas y sportapp.usuarios.proyeccion.dlq."
  }
}

run "rechaza_menos_de_cinco_entregas" {
  command = plan

  variables {
    max_delivery_attempts = 3
  }

  expect_failures = [var.max_delivery_attempts]
}

run "nombres_por_defecto" {
  command = plan

  variables {
    domain = "eventos"
  }

  assert {
    condition = (
      google_pubsub_subscription.projector.name == "sportapp.eventos.v1.read-projector" &&
      google_pubsub_topic.dead_letter.name == "sportapp.eventos.v1.dlq" &&
      google_pubsub_subscription.dead_letter_ops.name == "sportapp.eventos.v1.dlq.ops"
    )
    error_message = "Sin names se conservan los nombres anteriores del módulo."
  }
}
