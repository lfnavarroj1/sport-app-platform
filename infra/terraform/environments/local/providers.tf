# El contexto se fija siempre: el contexto activo de kubectl puede ser un
# clúster GKE y este ambiente nunca debe tocarlo.
provider "kubernetes" {
  config_path    = pathexpand(var.kubeconfig_path)
  config_context = var.kube_context
}

provider "kustomization" {
  kubeconfig_path = pathexpand(var.kubeconfig_path)
  context         = var.kube_context
}
