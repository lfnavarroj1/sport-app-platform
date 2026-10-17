# Credenciales: nunca llaves JSON (ADC con impersonación local o WIF en CI).
provider "google" {
  project                     = var.project_id
  region                      = var.region
  impersonate_service_account = var.impersonate_service_account
}

# Token de corta vida de la identidad que ejecuta Terraform; no queda en el estado.
ephemeral "google_client_config" "this" {}

# Endpoint DNS del clúster: autorizado por IAM y con certificado público, sin
# IP autorizadas ni CA del clúster.
provider "kubernetes" {
  host  = "https://${local.gke.dns_endpoint}"
  token = ephemeral.google_client_config.this.access_token
}

provider "kustomization" {
  kubeconfig_raw = yamlencode({
    apiVersion      = "v1"
    kind            = "Config"
    current-context = "gke"
    clusters        = [{ name = "gke", cluster = { server = "https://${local.gke.dns_endpoint}" } }]
    users           = [{ name = "terraform", user = { token = ephemeral.google_client_config.this.access_token } }]
    contexts        = [{ name = "gke", context = { cluster = "gke", user = "terraform", namespace = local.namespace } }]
  })
}
