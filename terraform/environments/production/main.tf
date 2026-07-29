data "google_project" "this" {
  project_id = var.project_id
}

locals {
  prefix = var.name_prefix
  labels = var.labels
}

# ---------------------------------------------------------------------------
# APIs. Every one of these needs an open billing account on the project.
# The bootstrap script verifies billing before it enables any prerequisite API.

resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "sqladmin.googleapis.com",
    "memorystore.googleapis.com",
    "redis.googleapis.com",
    "servicenetworking.googleapis.com",
    "networkconnectivity.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "storage.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudquotas.googleapis.com",
    "dns.googleapis.com",
    "certificatemanager.googleapis.com",
  ])

  project = var.project_id
  service = each.value

  # Never let `terraform destroy` disable an API — it cascades into other
  # projects' quota and is not what anyone means by "tear down my dev stack".
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# VPC

resource "google_compute_network" "vpc" {
  name                    = "${local.prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "gke" {
  name          = "${local.prefix}-gke-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr

  # Autopilot is VPC-native and requires both secondary ranges.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }

  private_ip_google_access = true
}

# Dedicated subnet for Private Service Connect (Memorystore auto-endpoints).
resource "google_compute_subnetwork" "psc" {
  name          = "${local.prefix}-psc-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.psc_cidr
}

# ---------------------------------------------------------------------------
# Private Services Access — Cloud SQL private IP rides this, NOT the PSC policy.
# The two are different mechanisms; Memorystore uses PSC below.

resource "google_compute_global_address" "psa" {
  name          = "${local.prefix}-psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]
  depends_on              = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# PSC policy for Memorystore

resource "google_network_connectivity_service_connection_policy" "memorystore" {
  name          = "${local.prefix}-memorystore-policy"
  location      = var.region
  service_class = "gcp-memorystore"
  description   = "Auto-created PSC endpoints for Memorystore Valkey"
  network       = google_compute_network.vpc.id

  psc_config {
    subnetworks = [google_compute_subnetwork.psc.id]
  }

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Cloud NAT — private Autopilot nodes have no external IPs, so without this
# the backend cannot reach api.anthropic.com, Monnify, or WhatsApp.

resource "google_compute_router" "router" {
  count   = var.enable_cloud_nat ? 1 : 0
  name    = "${local.prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  count  = var.enable_cloud_nat ? 1 : 0
  name   = "${local.prefix}-nat"
  router = google_compute_router.router[0].name
  region = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
