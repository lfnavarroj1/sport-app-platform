# Alertas base del ambiente: CPU de Cloud SQL, mensajes en DLQ, atraso de
# proyección CQRS y errores 5xx de Cloud Run. Los umbrales son iniciales y
# deben ajustarse con los SLO cuando se ratifiquen.

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.6"
    }
  }
}

variable "project_id" {
  description = "Proyecto GCP del ambiente."
  type        = string
}

variable "environment" {
  description = "Nombre del ambiente, para los títulos."
  type        = string
}

variable "notification_emails" {
  description = "Correos que reciben las alertas; vacío crea las alertas sin notificar."
  type        = list(string)
  default     = []
}

variable "projection_lag_seconds" {
  description = "Antigüedad máxima tolerada del mensaje más viejo sin ACK del proyector."
  type        = number
  default     = 300
}

resource "google_monitoring_notification_channel" "email" {
  for_each = toset(var.notification_emails)

  project      = var.project_id
  display_name = "SportApp ${var.environment} - ${each.value}"
  type         = "email"
  labels = {
    email_address = each.value
  }
}

locals {
  channels = [for c in google_monitoring_notification_channel.email : c.id]

  alerts = {
    cloudsql-cpu = {
      name       = "Cloud SQL con CPU alta"
      filter     = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/cpu/utilization\""
      threshold  = 0.8
      duration   = "600s"
      aligner    = "ALIGN_MEAN"
      reducer    = null
      group_by   = []
      doc_suffix = "Revisar consultas lentas en Query Insights y el tamaño de los pools."
    }
    pubsub-dlq = {
      name       = "Mensajes en DLQ"
      filter     = "resource.type = \"pubsub_subscription\" AND metric.type = \"pubsub.googleapis.com/subscription/num_undelivered_messages\" AND resource.label.subscription_id = monitoring.regex.full_match(\".*[.]dlq[.]ops\")"
      threshold  = 0
      duration   = "300s"
      aligner    = "ALIGN_MAX"
      reducer    = null
      group_by   = []
      doc_suffix = "Un proyector agotó los reintentos; inspeccionar la suscripción .dlq.ops."
    }
    projection-lag = {
      name       = "Atraso de proyección CQRS"
      filter     = "resource.type = \"pubsub_subscription\" AND metric.type = \"pubsub.googleapis.com/subscription/oldest_unacked_message_age\" AND resource.label.subscription_id = monitoring.regex.full_match(\".*[.]read-projector\")"
      threshold  = var.projection_lag_seconds
      duration   = "300s"
      aligner    = "ALIGN_MAX"
      reducer    = null
      group_by   = []
      doc_suffix = "El proyector de lectura no confirma mensajes a tiempo."
    }
    cloudrun-5xx = {
      name       = "Errores 5xx en Cloud Run"
      filter     = "resource.type = \"cloud_run_revision\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.label.response_code_class = \"5xx\""
      threshold  = 1
      duration   = "300s"
      aligner    = "ALIGN_RATE"
      reducer    = "REDUCE_SUM"
      group_by   = ["resource.label.service_name"]
      doc_suffix = "Más de 1 respuesta 5xx por segundo en un servicio web o BFF."
    }
  }
}

resource "google_monitoring_alert_policy" "this" {
  for_each = local.alerts

  project               = var.project_id
  display_name          = "[${var.environment}] ${each.value.name}"
  combiner              = "OR"
  notification_channels = local.channels

  conditions {
    display_name = each.value.name

    condition_threshold {
      filter          = each.value.filter
      comparison      = "COMPARISON_GT"
      threshold_value = each.value.threshold
      duration        = each.value.duration

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = each.value.aligner
        cross_series_reducer = each.value.reducer
        group_by_fields      = each.value.group_by
      }
    }
  }

  documentation {
    content   = each.value.doc_suffix
    mime_type = "text/markdown"
  }
}
