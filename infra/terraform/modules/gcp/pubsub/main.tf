# Mensajería de un dominio CQRS: tópico sportapp.<dominio>.v1, suscripción del
# proyector con reintentos y DLQ, y una suscripción operativa <dlq>.ops.
# Solo el publicador outbox publica y solo el proyector consume.

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

variable "project_number" {
  description = "Número del proyecto, para el agente de servicio de Pub/Sub."
  type        = string
}

variable "domain" {
  description = "Dominio CQRS, por ejemplo usuarios."
  type        = string
}

variable "settings" {
  description = "Retención, plazo de ACK, intentos y espera de reintento."
  type = object({
    message_retention_duration = string
    ack_deadline_seconds       = number
    max_delivery_attempts      = number
    minimum_backoff            = string
    maximum_backoff            = string
  })
}

variable "names" {
  description = "Suscripción del proyector y tópico DLQ que fija el contrato del dominio (CMP-002); null usa sportapp.<dominio>.v1.read-projector y sportapp.<dominio>.v1.dlq."
  type = object({
    projector_subscription = string
    dead_letter_topic      = string
  })
  default = null
}

variable "publisher_members" {
  description = "Miembros con roles/pubsub.publisher sobre el tópico, por clave estable."
  type        = map(string)
  default     = {}
}

variable "subscriber_members" {
  description = "Miembros con roles/pubsub.subscriber sobre la suscripción del proyector."
  type        = map(string)
  default     = {}
}

locals {
  topic_name             = "sportapp.${var.domain}.v1"
  projector_subscription = var.names == null ? "${local.topic_name}.read-projector" : var.names.projector_subscription
  dead_letter_topic      = var.names == null ? "${local.topic_name}.dlq" : var.names.dead_letter_topic
  pubsub_agent           = "serviceAccount:service-${var.project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_topic" "events" {
  project                    = var.project_id
  name                       = local.topic_name
  message_retention_duration = var.settings.message_retention_duration
}

resource "google_pubsub_topic" "dead_letter" {
  project                    = var.project_id
  name                       = local.dead_letter_topic
  message_retention_duration = var.settings.message_retention_duration
}

resource "google_pubsub_subscription" "projector" {
  project                    = var.project_id
  name                       = local.projector_subscription
  topic                      = google_pubsub_topic.events.id
  ack_deadline_seconds       = var.settings.ack_deadline_seconds
  message_retention_duration = var.settings.message_retention_duration
  enable_message_ordering    = true

  expiration_policy {
    ttl = ""
  }

  retry_policy {
    minimum_backoff = var.settings.minimum_backoff
    maximum_backoff = var.settings.maximum_backoff
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = var.settings.max_delivery_attempts
  }
}

resource "google_pubsub_subscription" "dead_letter_ops" {
  project                    = var.project_id
  name                       = "${local.dead_letter_topic}.ops"
  topic                      = google_pubsub_topic.dead_letter.id
  ack_deadline_seconds       = 60
  message_retention_duration = var.settings.message_retention_duration

  expiration_policy {
    ttl = ""
  }
}

# Pub/Sub reenvía a la DLQ con su agente de servicio: necesita publicar en la
# DLQ y suscribirse a la suscripción de origen.
resource "google_pubsub_topic_iam_member" "dead_letter_agent" {
  project = var.project_id
  topic   = google_pubsub_topic.dead_letter.name
  role    = "roles/pubsub.publisher"
  member  = local.pubsub_agent
}

resource "google_pubsub_subscription_iam_member" "dead_letter_agent" {
  project      = var.project_id
  subscription = google_pubsub_subscription.projector.name
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}

resource "google_pubsub_topic_iam_member" "publishers" {
  for_each = var.publisher_members

  project = var.project_id
  topic   = google_pubsub_topic.events.name
  role    = "roles/pubsub.publisher"
  member  = each.value
}

resource "google_pubsub_subscription_iam_member" "subscribers" {
  for_each = var.subscriber_members

  project      = var.project_id
  subscription = google_pubsub_subscription.projector.name
  role         = "roles/pubsub.subscriber"
  member       = each.value
}

output "topic" {
  description = "Tópico de eventos del dominio."
  value       = google_pubsub_topic.events.name
}

output "projector_subscription" {
  description = "Suscripción del proyector de lectura."
  value       = google_pubsub_subscription.projector.name
}

output "dead_letter_topic" {
  description = "Tópico DLQ de la suscripción del proyector."
  value       = google_pubsub_topic.dead_letter.name
}

output "dead_letter_subscription" {
  description = "Suscripción operativa sobre la DLQ."
  value       = google_pubsub_subscription.dead_letter_ops.name
}
