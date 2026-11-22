output "namespace" {
  description = "Namespace del ambiente."
  value       = local.namespace
}

output "endpoints" {
  description = "Accesos desde el equipo (Service LoadBalancer de Docker Desktop)."
  value = {
    web             = "http://localhost:18082"
    bff_web         = "http://localhost:18080"
    bff_mobile      = "http://localhost:18081"
    bff_mobile_avd  = "http://10.0.2.2:18081" # desde el emulador de Android
    postgres        = "localhost:15432"
    pubsub_emulator = "localhost:18085"
    pubsub_project  = "sportapp-local"
  }
}

output "commands" {
  description = "Comandos útiles (siempre con contexto y namespace explícitos)."
  value = {
    pods        = "kubectl --context ${var.kube_context} --namespace ${local.namespace} get pods"
    logs        = "kubectl --context ${var.kube_context} --namespace ${local.namespace} logs deployment/<componente>"
    db_password = "kubectl --context ${var.kube_context} --namespace ${local.namespace} get secret sportapp-database -o jsonpath=\"{.data.USUARIOS_DB_PASSWORD}\""
  }
}

output "strava" {
  description = "HU031: callback que se registra en el portal de Strava y recursos de mensajería (sin secretos)."
  value = {
    redirect_uri       = var.strava_redirect_uri
    callback_domain    = regex("^https?://([^/:]+)", var.strava_redirect_uri)[0]
    secret             = "sportapp-third-party"
    secret_keys        = ["STRAVA_CLIENT_ID", "STRAVA_CLIENT_SECRET", "STRAVA_TOKEN_KEY"]
    topic              = "sportapp.terceros.v1"
    subscription       = "entrenamientos-actividades-externas-v1"
    dead_letter_topic  = "sportapp.terceros.actividades.dlq"
    integration_active = local.strava_enabled
  }
}
