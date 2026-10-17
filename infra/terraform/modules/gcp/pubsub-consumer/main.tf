# Suscripción de un consumidor de integración sobre el tópico de otro dominio:
# entrega ordenada, filtro opcional, reintentos, DLQ propia y suscripción
# operativa <dlq>.ops. Solo los miembros indicados consumen.

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

variable "topic" {
  description = "Tópico que se consume (nombre o id)."
  type        = string
}

variable "subscription" {
  description = "Nombre de la suscripción del consumidor."
  type        = string
}

variable "dead_letter_topic" {
  description = "Nombre del tópico DLQ; la suscripción operativa es <dead_letter_topic>.ops."
  type        = string
}

variable "filter" {
  description = "Filtro de Pub/Sub sobre atributos; null entrega todos los mensajes del tópico. No puede cambiarse sin recrear la suscripción."
  type        = string
  default     = null
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

variable "subscriber_members" {
  description = "Miembros con roles/pubsub.subscriber sobre la suscripción, por clave estable."
  type        = map(string)
  default     = {}
}

locals {
  pubsub_agent = "serviceAccount:service-${var.project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_topic" "dead_letter" {
  project                    = var.project_id
  name                       = var.dead_letter_topic
  message_retention_duration = var.settings.message_retention_duration
}

resource "google_pubsub_subscription" "consumer" {
  project                    = var.project_id
  name                       = var.subscription
  topic                      = var.topic
  filter                     = var.filter
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
  name                       = "${var.dead_letter_topic}.ops"
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
  subscription = google_pubsub_subscription.consumer.name
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}

resource "google_pubsub_subscription_iam_member" "subscribers" {
  for_each = var.subscriber_members

  project      = var.project_id
  subscription = google_pubsub_subscription.consumer.name
  role         = "roles/pubsub.subscriber"
  member       = each.value
}

output "subscription" {
  description = "Suscripción del consumidor."
  value       = google_pubsub_subscription.consumer.name
}

output "dead_letter_topic" {
  description = "Tópico DLQ del consumidor."
  value       = google_pubsub_topic.dead_letter.name
}

output "dead_letter_subscription" {
  description = "Suscripción operativa sobre la DLQ."
  value       = google_pubsub_subscription.dead_letter_ops.name
}
