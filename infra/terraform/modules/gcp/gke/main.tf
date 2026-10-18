# Clúster GKE Standard con nodos privados, Workload Identity, Dataplane V2
# (NetworkPolicy) y complemento de Secret Manager. La ubicación decide si es
# zonal (una zona, desarrollo) o regional (tres zonas, producción).

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.6"
    }
  }
}

# Cuenta mínima de nodos: sin roles de editor ni la cuenta por defecto de Compute.
resource "google_service_account" "nodes" {
  project      = var.project_id
  account_id   = "gke-nodes"
  display_name = "Nodos GKE ${var.name}"
}

resource "google_project_iam_member" "nodes" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = google_service_account.nodes.member
}

resource "google_container_cluster" "this" {
  project  = var.project_id
  name     = var.name
  location = var.location

  network    = var.network
  subnetwork = var.subnetwork

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = var.deletion_protection

  networking_mode       = "VPC_NATIVE"
  datapath_provider     = "ADVANCED_DATAPATH"
  enable_shielded_nodes = true
  resource_labels       = var.labels

  release_channel {
    channel = var.release_channel
  }

  # Binary Authorization (deshabilitada hasta que existan attestations válidas):
  # habilitada, el clúster aplica la política única del proyecto.
  binary_authorization {
    evaluation_mode = var.binary_authorization_enabled ? "PROJECT_SINGLETON_POLICY_ENFORCE" : "DISABLED"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  # El endpoint DNS se autoriza con IAM: lo usan el operador y Cloud Deploy sin abrir IPs.
  # El endpoint IP queda limitado a las redes autorizadas (vacío = ninguna externa).
  control_plane_endpoints_config {
    dns_endpoint_config {
      allow_external_traffic = true
    }
    ip_endpoints_config {
      enabled = true
    }
  }

  master_authorized_networks_config {
    gcp_public_cidrs_access_enabled = false

    dynamic "cidr_blocks" {
      for_each = var.master_authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  secret_manager_config {
    enabled = true
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  maintenance_policy {
    recurring_window {
      start_time = "2026-01-03T06:00:00Z"
      end_time   = "2026-01-03T12:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }
}

resource "google_container_node_pool" "primary" {
  project  = var.project_id
  name     = "primary"
  cluster  = google_container_cluster.this.id
  location = var.location

  initial_node_count = 1 # por zona; luego decide el autoscaler

  # Suspendido: sin autoescalado y 0 nodos por zona. Al reanudar vuelve el
  # autoescalado y los nodos regresan cuando hay pods pendientes.
  node_count = var.suspended ? 0 : null

  # Totales del grupo, no por zona.
  dynamic "autoscaling" {
    for_each = var.suspended ? [] : [1]
    content {
      total_min_node_count = var.node_pool.min_nodes
      total_max_node_count = var.node_pool.max_nodes
      location_policy      = "ANY"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type    = var.node_pool.machine_type
    spot            = var.node_pool.spot
    disk_size_gb    = var.node_pool.disk_size_gb
    disk_type       = "pd-balanced"
    image_type      = "COS_CONTAINERD"
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    resource_labels = var.labels

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  depends_on = [google_project_iam_member.nodes]
}
