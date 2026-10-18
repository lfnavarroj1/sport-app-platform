output "namespace" {
  description = "Namespace productivo de las cargas en GKE."
  value       = kubernetes_namespace_v1.sportapp.metadata[0].name
}

output "services" {
  description = "Services del backend que administra Terraform (los Deployments y Jobs los administra Cloud Deploy)."
  value       = sort([for id in local.ids_services : element(split("/", id), length(split("/", id)) - 1)])
}

output "service_accounts" {
  description = "KSA creadas por Terraform; los manifiestos de Cloud Deploy las referencian por nombre."
  value       = sort(keys(kubernetes_service_account_v1.workload))
}

output "internal_apis" {
  description = "APIs expuestas a Cloud Run por balanceador interno: Service -> IP."
  value       = local.internal_apis
}

output "cloud_deploy_rbac_subject" {
  description = "Usuario RBAC con el que Cloud Deploy opera en el namespace."
  value       = local.deploy_execution
}
