# GKE Autopilot.
#
# Autopilot bills per-Pod resource *requests*, not per node and not per request.
# That is the single most important cost property of this deployment: the
# ~19.9M req/mo the desktop clients generate cost nothing extra here, so the
# polling-reduction work that dominated the Cloud Run estimate is worth almost
# nothing directly on Autopilot.
#
# Sizing (from docs/gke-autopilot-cost-study.md §A), all shared bridges:
#   next-backend  2 x 250m / 512Mi
#   worker        1 x 150m / 512Mi
#   synapse       1 x 300m / 1Gi
#   mautrix-whatsapp 1 x 120m / 768Mi
#   mautrix-meta     1 x 100m / 384Mi
# Pod requests must respect the 50m/52Mi per-Pod floor and the 1:1..1:6.5
# vCPU:memory ratio. Those live in the k8s manifests, not here.

resource "google_container_cluster" "autopilot" {
  provider = google-beta

  name     = "${local.prefix}-autopilot"
  location = var.region

  enable_autopilot = true

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.gke.id

  # Autopilot manages node pools itself; the provider still requires the
  # cluster to be VPC-native with named secondary ranges.
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false # public control plane, locked by the CIDR list below
    master_ipv4_cidr_block  = var.master_ipv4_cidr
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  # Keyless auth from pods to Cloud SQL, GCS, Memorystore and other Google
  # APIs. Secret Manager access belongs only to the External Secrets identity.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # The live cluster already runs the standard Gateway API channel. Declare it
  # here so a replacement cluster or disaster recovery build does not silently
  # omit the controller required by the GitOps Gateway/HTTPRoute manifests.
  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  release_channel {
    channel = "REGULAR"
  }

  # Managed Prometheus CANNOT be disabled on Autopilot (GKE >= 1.25 forces it
  # on; setting enabled = false returns HTTP 400). Do not re-add that block.
  #
  # This is fine cost-wise, contrary to my first pass: GMP bills on samples
  # ingested from WORKLOADS, and it does not scrape your pods until you create
  # a PodMonitoring / ClusterPodMonitoring CR. System-component metrics are
  # non-chargeable. So the ~$104/mo risk lives in the k8s manifests, not here —
  # the control is "don't create PodMonitoring CRs you can't justify".
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  deletion_protection = true

  resource_labels = local.labels

  depends_on = [
    google_project_service.apis,
    google_compute_subnetwork.gke,
  ]

  lifecycle {
    ignore_changes = [
      # Autopilot mutates these server-side; diffing them causes perpetual plans.
      node_config,
      initial_node_count,
    ]
  }
}

# ---------------------------------------------------------------------------
# Workload Identity.
#
# Keep google_service_account.app as the API identity so the existing GSA is
# not replaced. Worker and migrator receive separate identities; every KSA is
# bound in the onsell-app namespace and secret/storage grants live on the
# resource they protect rather than at project scope.

resource "google_service_account" "app" {
  account_id   = "${local.prefix}-app"
  display_name = "Onsell API (Workload Identity)"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "app_roles" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/cloudsql.instanceUser",
    "roles/monitoring.metricWriter",
    "roles/logging.logWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.app.email}"
}

# This resource address is intentionally retained. Changing the principal from
# default/onsell-app to onsell-app/onsell-api revokes the old broad binding.
resource "google_service_account_iam_member" "app_wi" {
  service_account_id = google_service_account.app.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[onsell-app/onsell-api]"
}

resource "google_service_account" "worker" {
  account_id   = "${local.prefix}-worker"
  display_name = "Onsell worker (Workload Identity)"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "worker_roles" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/cloudsql.instanceUser",
    "roles/monitoring.metricWriter",
    "roles/logging.logWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_service_account_iam_member" "worker_wi" {
  service_account_id = google_service_account.worker.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[onsell-app/onsell-worker]"
}

resource "google_service_account" "migrator" {
  account_id   = "${local.prefix}-migrator"
  display_name = "Onsell database migrator (Workload Identity)"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "migrator_roles" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/logging.logWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.migrator.email}"
}

resource "google_service_account_iam_member" "migrator_wi" {
  service_account_id = google_service_account.migrator.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[onsell-app/onsell-migrator]"
}

# Matrix is a separate trust boundary. These identities exist only when its
# dedicated Cloud SQL data plane is enabled, and their keys deliberately match
# the Kubernetes service-account names under infra/k8s/messaging.
locals {
  matrix_workload_identities = {
    synapse = {
      account_id   = "${local.prefix}-matrix-synapse"
      display_name = "Onsell Synapse (Workload Identity)"
      ksa_name     = "synapse"
    }
    mautrix-whatsapp = {
      account_id   = "${local.prefix}-matrix-whatsapp"
      display_name = "Onsell mautrix WhatsApp (Workload Identity)"
      ksa_name     = "mautrix-whatsapp"
    }
    mautrix-instagram = {
      account_id   = "${local.prefix}-matrix-instagram"
      display_name = "Onsell mautrix Instagram (Workload Identity)"
      ksa_name     = "mautrix-instagram"
    }
  }
}

resource "google_service_account" "matrix" {
  for_each = var.enable_matrix_cloudsql ? local.matrix_workload_identities : {}

  account_id   = each.value.account_id
  display_name = each.value.display_name
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "matrix_cloudsql_client" {
  for_each = google_service_account.matrix

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${each.value.email}"
}

resource "google_project_iam_member" "matrix_log_writer" {
  for_each = google_service_account.matrix

  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${each.value.email}"
}

resource "google_service_account_iam_member" "matrix_wi" {
  for_each = google_service_account.matrix

  service_account_id = each.value.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[onsell-messaging/${local.matrix_workload_identities[each.key].ksa_name}]"
}

# External Secrets Operator is the only in-cluster identity that materializes
# Secret Manager values as Kubernetes Secrets. It receives no project-level
# accessor role; platform.tf/data-stores.tf/cdn.tf grant exact secret resources.
resource "google_service_account" "external_secrets" {
  account_id   = "${local.prefix}-external-secrets"
  display_name = "External Secrets Operator (Workload Identity)"
  depends_on   = [google_project_service.apis]
}

resource "google_service_account_iam_member" "external_secrets_wi" {
  service_account_id = google_service_account.external_secrets.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[external-secrets/external-secrets]"
}
