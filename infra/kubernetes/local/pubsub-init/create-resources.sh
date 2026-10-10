#!/bin/sh
# Crea, por dominio CQRS, los mismos recursos que GCP:
#   sportapp.<dominio>.v1, .dlq, .read-projector (con reintentos y DLQ) y .dlq.ops
# Una respuesta 409 significa que el recurso ya existe.
set -eu

project="projects/${PUBSUB_PROJECT_ID}"
base="http://${PUBSUB_EMULATOR_HOST}/v1/${project}"

until curl -s -o /dev/null "http://${PUBSUB_EMULATOR_HOST}/"; do
  echo "esperando el emulador en ${PUBSUB_EMULATOR_HOST}..."
  sleep 2
done

put() {
  path="$1"
  body="${2:-}"
  [ -n "$body" ] || body='{}'
  response=$(curl -s -w '\n%{http_code}' -X PUT -H 'Content-Type: application/json' -d "$body" "${base}/${path}")
  code=$(printf '%s' "$response" | tail -n 1)
  case "$code" in
    200) echo "creado: ${path}" ;;
    409) echo "ya existe: ${path}" ;;
    *)
      printf 'error %s en %s\n%s\n' "$code" "$path" "$response" >&2
      exit 1
      ;;
  esac
}

for domain in $PUBSUB_DOMAINS; do
  topic="sportapp.${domain}.v1"
  put "topics/${topic}"
  put "topics/${topic}.dlq"
  put "subscriptions/${topic}.read-projector" "{\"topic\":\"${project}/topics/${topic}\",\"ackDeadlineSeconds\":60,\"enableMessageOrdering\":true,\"retryPolicy\":{\"minimumBackoff\":\"10s\",\"maximumBackoff\":\"600s\"},\"deadLetterPolicy\":{\"deadLetterTopic\":\"${project}/topics/${topic}.dlq\",\"maxDeliveryAttempts\":10}}"
  put "subscriptions/${topic}.dlq.ops" "{\"topic\":\"${project}/topics/${topic}.dlq\",\"ackDeadlineSeconds\":60}"
done
