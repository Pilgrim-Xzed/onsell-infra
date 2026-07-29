# Artifact Registry, buckets, and the secrets the app expects.

resource "google_artifact_registry_repository" "images" {
  location      = var.region
  repository_id = "${local.prefix}-images"
  format        = "DOCKER"
  description   = "Onsell backend runner, worker, and migrator images"
  labels        = local.labels

  # Untagged images from CI accumulate fast and Artifact Registry bills storage.
  cleanup_policies {
    id     = "keep-tagged-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 20
    }
  }
  cleanup_policies {
    id     = "delete-untagged"
    action = "DELETE"
    condition {
      tag_state  = "UNTAGGED"
      older_than = "604800s" # 7 days
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_artifact_registry_repository_iam_member" "gke_pull" {
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  # Autopilot nodes pull as the default compute SA.
  member = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

# ---------------------------------------------------------------------------
# Buckets
#
# Product images: today `image_url` is a plain text column and 100% of the
# 65,318 product images point at third-party CDNs (images.snoonu.com et al).
# This bucket is the origin for the ingest path that does not exist yet — see
# docs/gke-autopilot-cost-study.md §C.

resource "google_storage_bucket" "media" {
  name     = "${local.prefix}-media-${var.project_id}"
  location = var.region

  uniform_bucket_level_access = true
  # ENFORCED, not inherited. The project-level DRS exception we needed for the
  # cache-fill grant also made allUsers bindings possible here; this blocks
  # public access at the bucket layer regardless of what IAM policy allows, so
  # the guardrail survives the org-policy hole. Cloud CDN does not need public
  # objects — it reads as service-<n>@cloud-cdn-fill.
  public_access_prevention = "enforced"

  versioning {
    enabled = true
  }

  # Content-addressed keys are immutable, so anything orphaned is dead weight.
  lifecycle_rule {
    condition {
      age                = 30
      with_state         = "ARCHIVED"
      num_newer_versions = 3
    }
    action {
      type = "Delete"
    }
  }

  cors {
    origin          = ["*"]
    method          = ["GET", "HEAD"]
    response_header = ["Content-Type", "Cache-Control"]
    max_age_seconds = 3600
  }

  labels = local.labels
}

# Runtime media access is bucket-scoped. The application identity must never
# be able to modify the Terraform state or desktop update buckets.
resource "google_storage_bucket_iam_member" "app_media_objects" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.app.email}"
}

# Electron auto-update artifacts. Kept separate from media: different access
# pattern, different lifecycle, and the study recommends R2/GitHub Releases for
# this specific bucket where zero egress actually pays. Provisioned here so the
# GCS path works on day one.
resource "google_storage_bucket" "updates" {
  name                        = "${local.prefix}-desktop-updates-${var.project_id}"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  versioning {
    enabled = true
  }
  labels = local.labels
}

# ---------------------------------------------------------------------------
# Secrets the backend reads. Terraform creates the CONTAINERS only — values are
# added out-of-band so real credentials never land in state or in git.
#
#   echo -n "$VALUE" | gcloud secrets versions add onsell-monnify-secret-key \
#     --project=chrome-oven-503818-h4 --data-file=-
#
# Legacy secret names remain so adopting this configuration never deletes a
# credential container. New names mirror the runtime contract used by the API
# and worker manifests; values are still added out-of-band.

locals {
  app_secret_names = toset([
    # Payments.
    "monnify-api-key",
    "monnify-secret-key",
    "monnify-contract-code",
    "monnify-wallet-account-number",

    # AI and agentic runtime.
    "ai-gateway-api-key",
    "anthropic-api-key", # legacy; preserve until all environments use AI Gateway
    "mcp-bearer-token",

    # Matrix and mautrix application services.
    "matrix-admin-token",
    "matrix-registration-secret",
    "app-as-token",
    "app-hs-token",
    "wa-bridge-secret",
    "ig-bridge-secret",
    "wa-as-token",
    "ig-as-token",

    # Notifications.
    "resend-api-key",
    "twilio-account-sid",
    "twilio-auth-token",
    "twilio-from",
    "web-push-vapid-public-key",
    "web-push-vapid-private-key",

    # Realtime agent transport.
    "livekit-api-key",
    "livekit-api-secret",

    # Legacy web-session contract; currently unused but must not be destroyed.
    "session-secret",
  ])

}

resource "google_secret_manager_secret" "app" {
  for_each = local.app_secret_names

  secret_id           = "${local.prefix}-${each.value}"
  labels              = local.labels
  deletion_protection = true
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

# External Secrets is the sole Secret Manager reader in-cluster. Application,
# worker, and migrator pods consume the Kubernetes Secrets it materializes and
# therefore receive no redundant Secret Manager IAM bindings of their own.
resource "google_secret_manager_secret_iam_member" "external_secrets_app_access" {
  for_each  = google_secret_manager_secret.app
  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.external_secrets.email}"
}

# ---------------------------------------------------------------------------
# Existing media CDN frontend IP. Its :80/:443 listeners are created in cdn.tf;
# the GKE API Gateway uses the distinct address in api-edge.tf.

resource "google_compute_global_address" "ingress" {
  name       = "${local.prefix}-ingress-ip"
  depends_on = [google_project_service.apis]
}
