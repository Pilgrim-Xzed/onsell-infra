# Cloud CDN in front of the media bucket.
#
# IMPORTANT — infrastructure is the easy half. There is currently NO upload
# path in the application: `image_url` is a plain nullable text column on
# categories/brands/merchants/products (db/schema.sql:13,41,63,131), there is
# no multipart handler, no @google-cloud/storage, no presigned URLs anywhere in
# services/backend/src, and merchants paste a URL into a text field
# (apps/desktop/src/features/products/ProductFormScreen.tsx:549). The live
# dataset is 65,318 product images and 5,575 logos, 100% on third-party CDNs.
#
# Until an ingest path writes objects into this bucket, the CDN below caches an
# empty origin. See docs/gke-autopilot-cost-study.md §C.

variable "cdn_domain" {
  description = <<-EOT
    Domain to serve images from, e.g. "images.onsell.ai".

    Leave empty and only the free half is built (backend bucket + URL map), so
    you are not billed $18.25/mo for a forwarding rule that cannot serve
    traffic. Set it, point an A record at google_compute_global_address.ingress,
    then re-apply — the managed certificate will not issue until DNS resolves.
  EOT
  type        = string
  default     = "images.onsell.ai"
}

variable "cdn_http_redirect" {
  description = <<-EOT
    Create the :80 listener (redirecting to :443). Costs a SECOND forwarding
    rule ($18.25/mo).

    REQUIRED — do not turn this off to save money. I tried that.

    Google-managed SSL certificates validate domain ownership over PORT 80.
    With no :80 forwarding rule the certificate cannot be issued: it sits at
    PROVISIONING indefinitely and eventually goes FAILED_NOT_VISIBLE, even
    though DNS, CAA and AAAA are all correct. Verified here on 2026-07-28 —
    `curl http://images.onsell.ai` returned nothing while the cert hung.

    The $18.25/mo is the price of a publicly-trusted certificate on this load
    balancer, not an optional redirect. The only way to avoid it is to bring
    your own certificate instead of using a Google-managed one.
  EOT
  type        = bool
  default     = true
}

variable "cdn_default_ttl" {
  description = "Seconds. Safe to make this long: keys are content-addressed and immutable."
  type        = number
  default     = 3600
}

locals {
  cdn_enabled = var.cdn_domain != ""
}

# ---------------------------------------------------------------------------
# Public read on the media bucket.
#
# Cloud CDN's backend-bucket path requires the objects to be publicly readable
# (the alternative is signed URLs, which defeats edge caching). Product images
# ARE public content, so this is correct — but it is a real decision: anything
# written to this bucket is world-readable. Never put invoice PDFs, customer
# media, or inbound WhatsApp/IG attachments here. Those flow through the
# authenticated /api/merchant/inbox/media route and must stay private.

# BLOCKED BY ORG POLICY as of 2026-07-28. Applying this returns:
#   Error 412: One or more users named in the policy do not belong to a
#   permitted customer
# That is the signature of constraints/iam.allowedPolicyMemberDomains (Domain
# Restricted Sharing) on organization 718397272661. It is a deliberate security
# control — do not work around it. Two legitimate paths:
#   a) an Org Policy admin adds an exception for this project, then flip this
#      variable to true;
#   b) keep the bucket private and use Cloud CDN signed URLs / signed cookies,
#      which Cloud CDN supports natively at the edge.
variable "media_bucket_public" {
  description = "Grant allUsers objectViewer on the media bucket. Requires an org-policy exception."
  type        = bool
  default     = false
}

resource "google_storage_bucket_iam_member" "media_public" {
  count  = var.media_bucket_public ? 1 : 0
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# ---------------------------------------------------------------------------
# CDN-enabled backend

resource "google_compute_backend_bucket" "media" {
  name        = "${local.prefix}-media-backend"
  bucket_name = google_storage_bucket.media.name
  enable_cdn  = true
  description = "Product/merchant imagery, fronted by Cloud CDN"

  cdn_policy {
    cache_mode        = "CACHE_ALL_STATIC"
    client_ttl        = var.cdn_default_ttl
    default_ttl       = var.cdn_default_ttl
    max_ttl           = 86400
    negative_caching  = true
    serve_while_stale = 86400

    # With a signed-URL key attached, Cloud CDN validates the signature at the
    # edge and REFUSES unsigned requests — that is what lets the bucket stay
    # private under the org's Domain Restricted Sharing policy.
    #
    # This is the max age for a cached object served to signed requests. Keys
    # are content-addressed and immutable, so a long value is safe and is what
    # keeps the hit ratio high even though every URL carries a unique signature.
    signed_url_cache_max_age_sec = 86400

    # A missing image should not stampede the origin on every request.
    negative_caching_policy {
      code = 404
      ttl  = 120
    }
    # No cache_key_policy block: empty lists are already the default, and the
    # API does not echo the block back, so declaring it causes a perpetual diff.
  }
}

# ---------------------------------------------------------------------------
# Signed URLs.
#
# This is the answer to the org policy, not a workaround for it. The bucket
# stays private — no allUsers grant, DRS untouched — and Cloud CDN validates a
# signature at the edge before serving. Unsigned requests get 403 from the CDN
# itself, so nothing reaches the origin.
#
# Attaching the first key is also what makes GCP create the cache-fill service
# agent (service-<projectnumber>@cloud-cdn-fill.iam.gserviceaccount.com). It
# does not exist before this resource applies, which is why the IAM grant below
# depends on it.

resource "random_id" "cdn_signing_key" {
  # Cloud CDN keys are exactly 16 bytes, base64url, unpadded.
  byte_length = 16
}

resource "google_compute_backend_bucket_signed_url_key" "media" {
  name           = "${local.prefix}-media-key"
  key_value      = random_id.cdn_signing_key.b64_url
  backend_bucket = google_compute_backend_bucket.media.name
}

# The app signs URLs with this. Same value as the CDN key — Cloud CDN verifies
# HMAC-SHA1 over the URL, so both sides must hold it.
resource "google_secret_manager_secret" "cdn_signing_key" {
  secret_id           = "${local.prefix}-cdn-signing-key"
  labels              = local.labels
  deletion_protection = true
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "cdn_signing_key" {
  secret      = google_secret_manager_secret.cdn_signing_key.id
  secret_data = random_id.cdn_signing_key.b64_url
}

resource "google_secret_manager_secret_iam_member" "external_secrets_cdn_signing_key_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.cdn_signing_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.external_secrets.email}"
}

# Cloud CDN's cache-fill agent reads the private bucket on behalf of validated
# signed requests. This would replace the allUsers grant entirely.
#
# ALSO BLOCKED, tested 2026-07-28. Same error as the allUsers grant:
#   Error 412: One or more users named in the policy do not belong to a
#   permitted customer
# Domain Restricted Sharing rejects Google's own service agent too, because
# cloud-cdn-fill.iam.gserviceaccount.com is outside the org's allowed customer
# IDs. So signed URLs do NOT route around the policy: a backend-bucket origin
# needs an IAM grant on the bucket no matter how the edge authenticates.
#
# The signed-URL key above is still worth keeping — it means unsigned requests
# are refused at the edge — but serving needs one of:
#   a) an org-policy exception for this project (then flip this to true), or
#   b) a backend SERVICE origin instead of a backend bucket: the app pod reads
#      GCS with its own Workload Identity SA, which IS in an allowed domain,
#      and Cloud CDN caches in front of the pod.
variable "cdn_fill_grant" {
  description = "Grant the Cloud CDN cache-fill agent read on the media bucket. Requires an org-policy exception."
  type        = bool
  default     = false
}

resource "google_storage_bucket_iam_member" "cdn_fill" {
  count      = var.cdn_fill_grant ? 1 : 0
  bucket     = google_storage_bucket.media.name
  role       = "roles/storage.objectViewer"
  member     = "serviceAccount:service-${data.google_project.this.number}@cloud-cdn-fill.iam.gserviceaccount.com"
  depends_on = [google_compute_backend_bucket_signed_url_key.media]
}

# ---------------------------------------------------------------------------
# URL map.
#
# Deliberately a plain google_compute_url_map rather than a GKE Gateway: when
# the app Gateway lands you add a path matcher HERE and both share one
# forwarding rule, instead of paying $18.25/mo twice. That is the "$1.20/mo
# marginal" figure from the study — it assumes a shared LB.

resource "google_compute_url_map" "cdn" {
  name            = "${local.prefix}-cdn"
  default_service = google_compute_backend_bucket.media.id
}

# HTTP -> HTTPS redirect map. Costs a second forwarding rule ($18.25/mo); drop
# it if a desktop app that hardcodes its URL is the only client.
resource "google_compute_url_map" "redirect" {
  count = local.cdn_enabled && var.cdn_http_redirect ? 1 : 0
  name  = "${local.prefix}-cdn-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

# ---------------------------------------------------------------------------
# TLS + frontend. Only built once cdn_domain is set.

resource "google_compute_managed_ssl_certificate" "cdn" {
  count = local.cdn_enabled ? 1 : 0
  name  = "${local.prefix}-cdn-cert"

  managed {
    domains = [var.cdn_domain]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_target_https_proxy" "cdn" {
  count            = local.cdn_enabled ? 1 : 0
  name             = "${local.prefix}-cdn-https-proxy"
  url_map          = google_compute_url_map.cdn.id
  ssl_certificates = [google_compute_managed_ssl_certificate.cdn[0].id]
}

resource "google_compute_global_forwarding_rule" "cdn_https" {
  count      = local.cdn_enabled ? 1 : 0
  name       = "${local.prefix}-cdn-https"
  target     = google_compute_target_https_proxy.cdn[0].id
  port_range = "443"
  ip_address = google_compute_global_address.ingress.address
}

resource "google_compute_target_http_proxy" "redirect" {
  count   = local.cdn_enabled && var.cdn_http_redirect ? 1 : 0
  name    = "${local.prefix}-cdn-http-redirect"
  url_map = google_compute_url_map.redirect[0].id
}

resource "google_compute_global_forwarding_rule" "cdn_http" {
  count      = local.cdn_enabled && var.cdn_http_redirect ? 1 : 0
  name       = "${local.prefix}-cdn-http"
  target     = google_compute_target_http_proxy.redirect[0].id
  port_range = "80"
  ip_address = google_compute_global_address.ingress.address
}

# ---------------------------------------------------------------------------

output "cdn_status" {
  value = local.cdn_enabled ? "https://${var.cdn_domain} -> ${google_compute_global_address.ingress.address}" : "origin+backend only — set cdn_domain and re-apply to serve traffic"
}
