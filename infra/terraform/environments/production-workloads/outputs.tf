output "namespace" {
  description = "Namespace de las cargas en GKE."
  value       = kubernetes_namespace_v1.sportapp.metadata[0].name
}

output "workloads" {
  description = "Deployments aplicados en GKE."
  value       = sort([for id in local.ids_workload : element(split("/", id), length(split("/", id)) - 1)])
}

output "migrations" {
  description = "Jobs de migración que terminaron antes de habilitar las réplicas."
  value       = sort([for id in local.ids_jobs : element(split("/", id), length(split("/", id)) - 1)])
}

output "internal_apis" {
  description = "APIs expuestas a Cloud Run por balanceador interno: Service -> IP."
  value       = local.platform.gke_internal_apis
}
