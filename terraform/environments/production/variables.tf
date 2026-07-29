terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.40"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.42"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state. Created by bootstrap.sh BEFORE the first `terraform init`,
  # because a bucket cannot be both the backend and a managed resource.
  backend "gcs" {
    bucket = "onsell-tfstate-chrome-oven-503818-h4"
    prefix = "prod"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # billingbudgets (and other "consumer" APIs) reject user-credential calls
  # that carry no quota project. Without these two the budget 403s with
  # "requires a quota project, which is not set by default".
  user_project_override = true
  billing_project       = var.project_id
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# ---------------------------------------------------------------------------
# Project / location

variable "project_id" {
  description = "GCP project. Pinned explicitly — the active gcloud config points at a different project."
  type        = string
  default     = "chrome-oven-503818-h4"
}

variable "region" {
  description = <<-EOT
    africa-south1 (Johannesburg). Verified 2026-07-28 against the Cloud Billing
    Catalog API to carry every SKU this stack needs:
      Autopilot pod memory   $0.0054202/GiB-h  (vs europe-west2 $0.0063421 — 14.5% cheaper)
      Cloud SQL Ent. vCPU    $0.0413/h         (vs europe-west2 $0.0496    — 17%   cheaper)
      Cloud SQL Ent. RAM     $0.0070/GiB-h     (vs europe-west2 $0.0084)
      Valkey Shared Core Nano $0.0350/h        (vs europe-west2 custom-pico $0.0351)
  EOT
  type        = string
  default     = "africa-south1"
}

variable "zone" {
  description = "Single zone for disposable cache resources. Durable stores are REGIONAL/MULTI_ZONE."
  type        = string
  default     = "africa-south1-a"
}

variable "name_prefix" {
  type    = string
  default = "onsell"
}

variable "labels" {
  type = map(string)
  default = {
    app         = "onsell"
    managed-by  = "terraform"
    environment = "production"
  }
}

# ---------------------------------------------------------------------------
# Networking

variable "subnet_cidr" {
  description = "Primary range for GKE nodes."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "services_cidr" {
  type    = string
  default = "10.30.0.0/20"
}

variable "psc_cidr" {
  description = "Private Service Connect range for Memorystore. Must be /29 or larger."
  type        = string
  default     = "10.40.0.0/24"
}

variable "master_ipv4_cidr" {
  description = "GKE control plane range. /28, must not overlap anything else."
  type        = string
  default     = "172.16.0.0/28"
}

variable "authorized_networks" {
  description = <<-EOT
    CIDRs allowed to reach the GKE control plane. Default is deny-all, which
    means kubectl only works from inside the VPC or via Cloud Shell. Add your
    office/VPN egress IP as x.x.x.x/32 before you try to deploy anything.
  EOT
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

# ---------------------------------------------------------------------------
# Cloud SQL — the app database (ledger_entries, payouts: real money, wants PITR)

variable "app_db_tier" {
  description = "db-custom-{vCPU}-{MB RAM}. 1 vCPU / 3.75 GiB ~= $49.31/mo compute in africa-south1."
  type        = string
  default     = "db-custom-1-3840"
}

variable "app_db_disk_gb" {
  type    = number
  default = 20
}

variable "app_db_ha" {
  description = <<-EOT
    REGIONAL (synchronous standby in a second zone) vs ZONAL.

    ON by default, and this is the ONE place in this stack worth paying for.
    ~$53 -> ~$98/mo, +$45.

    Why here and nowhere else: this database holds ledger_entries and payouts —
    settled money. Zonal means a single-zone failure takes it offline until
    Google restores the zone or you restore from backup, an RTO measured in
    hours during which no order can complete and no payout can be recorded.
    REGIONAL fails over automatically in ~60s.

    This database is not rebuildable: it holds the financial ledger and payout
    state. Matrix/bridge session state also needs its own durable, tested
    recovery path and is outside this variable.

    Set false only for a dev/staging copy, never for the environment taking
    real money.
  EOT
  type        = bool
  default     = true
}

variable "app_db_deletion_protection" {
  description = "Keep true. This database holds settled money."
  type        = bool
  default     = true

  validation {
    condition     = var.app_db_deletion_protection
    error_message = "Production app database deletion protection must remain enabled."
  }
}

# ---------------------------------------------------------------------------
# Cloud SQL — Matrix and the two mautrix bridges

variable "matrix_db_tier" {
  description = "Dedicated HA PostgreSQL tier for Synapse + bridge session state."
  type        = string
  default     = "db-custom-1-3840"
}

variable "matrix_db_disk_gb" {
  description = "Initial SSD capacity. Auto-resize is capped at 5x this value."
  type        = number
  default     = 20
}

# ---------------------------------------------------------------------------
# Memorystore (Valkey)

variable "valkey_node_type" {
  description = "SHARED_CORE_NANO is the cheapest ($0.035/h = $25.55/mo)."
  type        = string
  default     = "SHARED_CORE_NANO"
}

variable "valkey_mode" {
  description = <<-EOT
    CLUSTER_DISABLED is REQUIRED, not a preference.

    src/lib/inbox-typing-bus.ts uses ordinary Redis pub/sub for typing fan-out.
    Valkey in CLUSTER mode implements *shard* pub/sub, where a PUBLISH only
    reaches subscribers on the same shard — the typing stream would silently
    deliver to a subset of readers. Verify this enum against the live API on
    first apply; if it rejects, fall back to google_redis_instance BASIC.
  EOT
  type        = string
  default     = "CLUSTER_DISABLED"
}

variable "valkey_replica_count" {
  description = "0 for launch. 1 adds a replica and roughly doubles the line."
  type        = number
  default     = 0
}

# ---------------------------------------------------------------------------
# Toggles — how the study's LEAN / BALANCED / SAFE configurations map to flags

variable "enable_matrix_cloudsql" {
  description = <<-EOT
    Provision a separate REGIONAL PostgreSQL 16 instance for Synapse and the
    WhatsApp/Instagram mautrix bridges. It is private-IP only, encrypted in
    transit, deletion-protected, and has PITR enabled. Keep false until the
    Matrix workloads and a tested restore runbook are ready.
  EOT
  type        = bool
  default     = false
}

variable "enable_cloud_nat" {
  description = "Required for private nodes to reach the internet (Anthropic API, Monnify, WhatsApp)."
  type        = bool
  default     = true
}

variable "billing_account_id" {
  description = "Billing account the budget attaches to. Budget creation needs billing.budgets.create on it."
  type        = string
  default     = "019831-660030-546803"
}
