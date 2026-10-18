output "github_connection" {
  description = "Conexión de Cloud Build con GitHub. Autorícela una vez en la consola de GCP y aplique con github_connection_ready = true."
  value = {
    name        = google_cloudbuildv2_connection.github.name
    console_url = "https://console.cloud.google.com/cloud-build/repositories/2nd-gen?project=${var.management_project_id}"
    ready       = var.github_connection_ready
  }
}

output "release_triggers" {
  description = "Triggers de release por tag y si están habilitados."
  value       = { for k, t in google_cloudbuild_trigger.release : t.name => !t.disabled }
}

output "promote_trigger" {
  description = "Trigger manual del promotor (se ejecuta desde la consola o gcloud del operador)."
  value       = one([for t in google_cloudbuild_trigger.promote : t.name])
}

output "evidence_buckets" {
  description = "Bucket de evidencia por componente."
  value       = { for k, b in google_storage_bucket.evidence : k => b.name }
}

output "pipelines" {
  description = "Pipeline de Cloud Deploy -> targets en orden."
  value       = { for name, p in local.pipelines : name => [for s in p.stages : s.target] }
}
