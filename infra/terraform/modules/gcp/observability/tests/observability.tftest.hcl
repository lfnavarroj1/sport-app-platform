# Pruebas de plan con proveedor simulado: no requieren credenciales ni crean
# recursos. Ejecutar desde modules/gcp/observability:
#   terraform init -backend=false
#   terraform test

mock_provider "google" {}

variables {
  project_id  = "sportapp-test"
  environment = "staging"
  projector_subscriptions = [
    "sportapp.usuarios.v1.read-projector",
    "proyector-entrenamientos-v1",
  ]
}

run "alertas_de_proyeccion_y_dlq" {
  command = plan

  # HU010: el atraso del proyector de entrenamientos se vigila por su nombre de contrato.
  assert {
    condition = endswith(
      google_monitoring_alert_policy.this["projection-lag"].conditions[0].condition_threshold[0].filter,
      "resource.label.subscription_id = one_of(\"sportapp.usuarios.v1.read-projector\", \"proyector-entrenamientos-v1\")",
    )
    error_message = "La alerta de atraso vigila exactamente las suscripciones de los proyectores."
  }

  # sportapp.entrenamientos.proyeccion.dlq.ops termina en .dlq.ops.
  assert {
    condition = strcontains(
      google_monitoring_alert_policy.this["pubsub-dlq"].conditions[0].condition_threshold[0].filter,
      "monitoring.regex.full_match(\".*[.]dlq[.]ops\")",
    )
    error_message = "La alerta de DLQ vigila todas las suscripciones operativas .dlq.ops."
  }
}

run "rechaza_alerta_sin_suscripciones" {
  command = plan

  variables {
    projector_subscriptions = []
  }

  expect_failures = [var.projector_subscriptions]
}
