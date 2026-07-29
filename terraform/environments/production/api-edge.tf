# Dedicated public edge identity for the GKE Gateway.
#
# The existing onsell-ingress-ip belongs to the media CDN's :80/:443 forwarding
# rules and cannot also be claimed by a separately managed GKE Gateway. Keep it
# untouched and give the API its own NamedAddress.

variable "api_domain" {
  description = "Public API hostname in the delegated Cloud DNS zone."
  type        = string
  default     = "api.k8s.onsell.ai"
}

resource "google_compute_global_address" "api_ingress" {
  name       = "${local.prefix}-api-ingress-ip"
  depends_on = [google_project_service.apis]
}

# Certificate Manager uses DNS authorization, so issuance does not depend on
# the Gateway already listening on port 80. The Gateway references the map by
# the stable name `onsell-api-production`.
resource "google_certificate_manager_dns_authorization" "api" {
  name     = "${local.prefix}-api-production"
  domain   = trimsuffix(var.api_domain, ".")
  location = "global"
  type     = "FIXED_RECORD"
  labels   = local.labels

  depends_on = [google_project_service.apis]
}

resource "google_dns_record_set" "api_certificate_authorization" {
  managed_zone = google_dns_managed_zone.k8s.name
  name         = google_certificate_manager_dns_authorization.api.dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.api.dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.api.dns_resource_record[0].data]
}

resource "google_certificate_manager_certificate" "api" {
  name        = "${local.prefix}-api-production"
  description = "Managed certificate for ${trimsuffix(var.api_domain, ".")}"
  location    = "global"
  scope       = "DEFAULT"
  labels      = local.labels

  managed {
    domains            = [trimsuffix(var.api_domain, ".")]
    dns_authorizations = [google_certificate_manager_dns_authorization.api.id]
  }
}

resource "google_certificate_manager_certificate_map" "api" {
  name        = "${local.prefix}-api-production"
  description = "GKE Gateway certificate map for the Onsell API"
  labels      = local.labels

  depends_on = [google_project_service.apis]
}

resource "google_certificate_manager_certificate_map_entry" "api" {
  name         = "${local.prefix}-api-production-entry"
  map          = google_certificate_manager_certificate_map.api.name
  hostname     = trimsuffix(var.api_domain, ".")
  certificates = [google_certificate_manager_certificate.api.id]
}

# ExternalDNS is intentionally scoped to Service/Ingress sources and does not
# publish Gateway/HTTPRoute hostnames. Terraform owns this single A record.
resource "google_dns_record_set" "api" {
  managed_zone = google_dns_managed_zone.k8s.name
  name         = "${trimsuffix(var.api_domain, ".")}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.api_ingress.address]
}

output "api_ingress_ip" {
  description = "NamedAddress onsell-api-ingress-ip used by the GKE Gateway."
  value       = google_compute_global_address.api_ingress.address
}

output "api_certificate_map" {
  description = "Value for the Gateway networking.gke.io/certmap annotation."
  value       = google_certificate_manager_certificate_map.api.name
}
