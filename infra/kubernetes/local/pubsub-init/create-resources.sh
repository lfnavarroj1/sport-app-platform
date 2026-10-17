#!/bin/sh
# Crea en el emulador los mismos recursos que GCP (infra/terraform/modules/gcp/pubsub).
# Cada línea de PUBSUB_PROJECTIONS es "<tópico> <suscripción del proyector> <DLQ>"
# y produce el tópico, la DLQ, la suscripción ordenada del proyector (10 entregas,
# espera de 10 a 600 s) y la suscripción operativa <DLQ>.ops.
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

printf '%s\n' "$PUBSUB_PROJECTIONS" | while read -r topic subscription dlq extra; do
  [ -n "$topic" ] || continue
  if [ -z "${dlq:-}" ] || [ -n "${extra:-}" ]; then
    echo "línea inválida en PUBSUB_PROJECTIONS: ${topic} ${subscription:-} ${dlq:-} ${extra:-}" >&2
    exit 1
  fi
  put "topics/${topic}"
  put "topics/${dlq}"
  put "subscriptions/${subscription}" "{\"topic\":\"${project}/topics/${topic}\",\"ackDeadlineSeconds\":60,\"enableMessageOrdering\":true,\"retryPolicy\":{\"minimumBackoff\":\"10s\",\"maximumBackoff\":\"600s\"},\"deadLetterPolicy\":{\"deadLetterTopic\":\"${project}/topics/${dlq}\",\"maxDeliveryAttempts\":10}}"
  put "subscriptions/${dlq}.ops" "{\"topic\":\"${project}/topics/${dlq}\",\"ackDeadlineSeconds\":60}"
done
