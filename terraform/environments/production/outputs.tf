output "cluster_name" {
  value = google_container_cluster.autopilot.name
}

output "kubectl_config_command" {
  description = "Run this to point kubectl at the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.autopilot.name} --region ${var.region} --project ${var.project_id}"
}

output "app_db_connection_name" {
  description = "For the Cloud SQL proxy sidecar / migrate Job."
  value       = google_sql_database_instance.app.connection_name
}

output "app_db_private_ip" {
  value = google_sql_database_instance.app.private_ip_address
}

output "matrix_db_connection_name" {
  description = "Cloud SQL Auth Proxy target for Matrix workloads, or null when disabled."
  value       = try(google_sql_database_instance.matrix[0].connection_name, null)
}

output "database_url_secret" {
  description = "Secret Manager id holding the API IAM-authenticated loopback DATABASE_URL."
  value       = google_secret_manager_secret.database_url.secret_id
}

output "worker_database_url_secret" {
  description = "Secret Manager id holding the worker IAM-authenticated loopback DATABASE_URL."
  value       = google_secret_manager_secret.worker_database_url.secret_id
}

output "migration_database_url_secret" {
  description = "Secret Manager id holding the migrator-only loopback DATABASE_URL."
  value       = google_secret_manager_secret.migration_database_url.secret_id
}

output "matrix_database_url_secrets" {
  description = "Per-workload Matrix database URL secret ids; empty when Matrix Cloud SQL is disabled."
  value       = { for key, secret in google_secret_manager_secret.matrix_database_url : key => secret.secret_id }
}

output "matrix_runtime_secret_contracts" {
  description = "Exact non-database Matrix Secret Manager ids consumed by the messaging manifests; empty when disabled."
  value       = { for key, secret in google_secret_manager_secret.matrix_runtime : key => secret.secret_id }
}

output "valkey_endpoints" {
  description = "PSC endpoints for the disposable cache and durable IAM/TLS security plane."
  value = {
    cache    = google_memorystore_instance.cache.endpoints
    security = google_memorystore_instance.security.endpoints
  }
}

output "redis_secret_contracts" {
  description = "Exact Secret Manager ids consumed by the runtime manifests."
  value       = { for key, secret in google_secret_manager_secret.redis : key => secret.secret_id }
}

output "artifact_registry" {
  description = "Docker push target."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "media_bucket" {
  value = google_storage_bucket.media.name
}

output "ingress_ip" {
  description = "Legacy media CDN IP. Do not attach the GKE API Gateway to it."
  value       = google_compute_global_address.ingress.address
}

output "workload_identity_service_account" {
  description = "Deprecated compatibility output: annotate KSA onsell-app/onsell-api with this."
  value       = google_service_account.app.email
}

output "workload_identity_service_accounts" {
  description = "Dedicated GSA emails for the three runtime KSAs in namespace onsell-app."
  value = {
    api      = google_service_account.app.email
    worker   = google_service_account.worker.email
    migrator = google_service_account.migrator.email
  }
}

output "matrix_workload_identity_service_accounts" {
  description = "Exact onsell-messaging KSA to GSA bindings; empty when Matrix Cloud SQL is disabled."
  value = {
    for key, service_account in google_service_account.matrix : key => {
      ksa = "onsell-messaging/${local.matrix_workload_identities[key].ksa_name}"
      gsa = service_account.email
    }
  }
}

output "external_secrets_service_account" {
  description = "Annotate KSA external-secrets/external-secrets with this GSA."
  value       = google_service_account.external_secrets.email
}

output "estimated_monthly_cost" {
  description = "USD estimates for africa-south1 at ~730h/month; traffic, logs, NAT and Autopilot pods are additional."
  value = {
    cloud_sql_app      = var.app_db_ha ? "~$98/mo (REGIONAL)" : "~$53/mo (ZONAL, dev only)"
    cloud_sql_matrix   = var.enable_matrix_cloudsql ? "~$98/mo (REGIONAL, same base tier as app)" : "$0 (disabled)"
    valkey_cache       = "~$25.55/mo (${var.valkey_node_type}, ${var.valkey_replica_count} replicas)"
    valkey_security    = "~$208.05/mo for 2 STANDARD_SMALL nodes + roughly $3-5/mo AOF persistence"
    api_gateway_edge   = "~$36.50/mo for the :80/:443 forwarding rules created by GKE Gateway; reserved IP is free while attached"
    cloud_armor        = "~$11/mo for 1 policy + 6 rules, plus $0.75/million requests (Standard)"
    gke_mgmt_fee       = "$73/mo, offset by the $74.40 free-tier credit for ONE zonal/Autopilot cluster per BILLING ACCOUNT"
    important_excludes = "Autopilot pods (~$67-84), Cloud NAT, logs, DNS queries, inter-zone/egress traffic, and the separate CDN forwarding rules."
  }
}
