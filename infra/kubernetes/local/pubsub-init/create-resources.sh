#!/bin/sh
# Crea en el emulador los mismos recursos que GCP (infra/terraform/modules/gcp).
#   PUBSUB_TOPICS: tópicos separados por espacios.
#   PUBSUB_SUBSCRIPTIONS: una línea "<suscripción> <tópico> <DLQ> <entregas> [filtro]"
#     por suscripción ordenada con espera de 10 a 600 s; crea también la DLQ y la
#     suscripción operativa <DLQ>.ops. El filtro es el resto de la línea.
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

for topic in $PUBSUB_TOPICS; do
  put "topics/${topic}"
done

printf '%s\n' "$PUBSUB_SUBSCRIPTIONS" | while read -r subscription topic dlq attempts filter; do
  [ -n "$subscription" ] || continue
  case "${attempts:-}" in
    '' | *[!0-9]*)
      echo "línea inválida en PUBSUB_SUBSCRIPTIONS: ${subscription} ${topic:-} ${dlq:-} ${attempts:-}" >&2
      exit 1
      ;;
  esac
  filter_json=""
  if [ -n "${filter:-}" ]; then
    filter_json=",\"filter\":\"$(printf '%s' "$filter" | sed 's/\\/\\\\/g; s/"/\\"/g')\""
  fi
  put "topics/${dlq}"
  put "subscriptions/${subscription}" "{\"topic\":\"${project}/topics/${topic}\",\"ackDeadlineSeconds\":60,\"enableMessageOrdering\":true${filter_json},\"retryPolicy\":{\"minimumBackoff\":\"10s\",\"maximumBackoff\":\"600s\"},\"deadLetterPolicy\":{\"deadLetterTopic\":\"${project}/topics/${dlq}\",\"maxDeliveryAttempts\":${attempts}}}"
  put "subscriptions/${dlq}.ops" "{\"topic\":\"${project}/topics/${dlq}\",\"ackDeadlineSeconds\":60}"
done
