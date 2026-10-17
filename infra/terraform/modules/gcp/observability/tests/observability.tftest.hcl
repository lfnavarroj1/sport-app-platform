# Pruebas de plan con proveedor simulado: no requieren credenciales ni crean
# recursos. Ejecutar desde modules/gcp/observability:
#   terraform init -backend=false
#   terraform test

mock_provider "google" {}

variables {
  project_id  = "sportapp-test"
  environment = "staging"
  consumer_subscriptions = [
    "proyector-usuarios-v1",
    "proyector-entrenamientos-v1",
    "sportapp.afiliacion.alta-gratuita.v1",
  ]
}

run "alertas_de_proyeccion_y_dlq" {
  command = plan

  # HU010 y HU001: proyectores y alta gratuita se vigilan por su nombre de contrato.
  assert {
    condition = endswith(
      google_monitoring_alert_policy.this["projection-lag"].conditions[0].condition_threshold[0].filter,
      "resource.label.subscription_id = one_of(\"proyector-usuarios-v1\", \"proyector-entrenamientos-v1\", \"sportapp.afiliacion.alta-gratuita.v1\")",
    )
    error_message = "La alerta de atraso vigila exactamente las suscripciones de proyectores y consumidores."
  }

  # sportapp.entrenamientos.proyeccion.dlq.ops, sportapp.usuarios.proyeccion.dlq.ops y
  # sportapp.afiliacion.alta-gratuita.dlq.ops terminan en .dlq.ops.
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
    consumer_subscriptions = []
  }

  expect_failures = [var.consumer_subscriptions]
}
