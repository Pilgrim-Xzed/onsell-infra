# Cloud DNS zone for a DELEGATED subdomain, plus the identity ExternalDNS uses.
#
# onsell.ai itself lives on Cloudflare (vick/sierra.ns.cloudflare.com). Rather
# than hand the cluster a Cloudflare API token with write access to the apex
# and MX records, we delegate one subdomain to Cloud DNS and let ExternalDNS
# authenticate with Workload Identity.
#
# What that buys: there is no static credential in the cluster to rotate, leak,
# or find in a compromised pod — and the blast radius of a compromised
# ExternalDNS is exactly this subdomain. It cannot touch onsell.ai, www, or
# your mail records, which a zone-scoped Cloudflare token still could.
#
# ONE MANUAL STEP: after `terraform apply`, add the NS records this zone
# reports (output `dns_delegation_ns`) to Cloudflare as an NS record set on
# `k8s`. Until you do, nothing under k8s.onsell.ai resolves.

variable "dns_delegated_zone" {
  description = "Subdomain delegated to Cloud DNS. Trailing dot required."
  type        = string
  default     = "k8s.onsell.ai."
}

resource "google_dns_managed_zone" "k8s" {
  name        = "${local.prefix}-k8s"
  dns_name    = var.dns_delegated_zone
  description = "Delegated from Cloudflare; managed by ExternalDNS in-cluster"
  labels      = local.labels

  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# ExternalDNS identity.

resource "google_service_account" "external_dns" {
  account_id   = "${local.prefix}-external-dns"
  display_name = "ExternalDNS (Workload Identity)"
  depends_on   = [google_project_service.apis]
}

# ZONE-scoped, not project-scoped. roles/dns.admin at the project would let a
# compromised ExternalDNS edit every zone in the project, including any you add
# later. This grant stops at the delegated subdomain.
resource "google_dns_managed_zone_iam_member" "external_dns" {
  managed_zone = google_dns_managed_zone.k8s.name
  role         = "roles/dns.admin"
  member       = "serviceAccount:${google_service_account.external_dns.email}"
}

# ExternalDNS also lists zones to find the one matching its --domain-filter.
# That is a project-level read and has no zone-scoped equivalent.
resource "google_project_iam_member" "external_dns_reader" {
  project = var.project_id
  role    = "roles/dns.reader"
  member  = "serviceAccount:${google_service_account.external_dns.email}"
}

resource "google_service_account_iam_member" "external_dns_wi" {
  service_account_id = google_service_account.external_dns.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[external-dns/external-dns]"
}

# ---------------------------------------------------------------------------

output "dns_delegation_ns" {
  description = "Add these at Cloudflare as NS records on `k8s` before anything resolves."
  value       = google_dns_managed_zone.k8s.name_servers
}

output "external_dns_service_account" {
  value = google_service_account.external_dns.email
}
