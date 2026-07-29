# Cloud SQL (app + optional Matrix) and Memorystore for Valkey.

# ---------------------------------------------------------------------------
# App database

resource "random_password" "app_db" {
  length  = 32
  special = true
  # Cloud SQL rejects these in passwords.
  override_special = "!#%*()-_=+[]{}<>:?"
}

resource "google_sql_database_instance" "app" {
  name             = "${local.prefix}-app-pg"
  region           = var.region
  database_version = "POSTGRES_16"

  deletion_protection = var.app_db_deletion_protection

  settings {
    tier                        = var.app_db_tier
    edition                     = "ENTERPRISE"
    availability_type           = var.app_db_ha ? "REGIONAL" : "ZONAL"
    deletion_protection_enabled = var.app_db_deletion_protection
    connector_enforcement       = "REQUIRED"

    disk_type       = "PD_SSD"
    disk_size       = var.app_db_disk_gb
    disk_autoresize = true
    # Cloud SQL storage auto-grows and never shrinks — cap it so a runaway
    # write cannot silently ratchet the bill.
    disk_autoresize_limit = var.app_db_disk_gb * 5

    backup_configuration {
      enabled                        = true
      start_time                     = "02:00"
      point_in_time_recovery_enabled = true # the whole reason this is managed
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 14
        retention_unit   = "COUNT"
      }
    }

    ip_configuration {
      ipv4_enabled                                  = false # private IP only
      private_network                               = google_compute_network.vpc.id
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 3
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    user_labels = local.labels
  }

  depends_on = [google_service_networking_connection.psa]
}

resource "google_sql_database" "app" {
  name     = "onsell"
  instance = google_sql_database_instance.app.name
  # Matches db/schema.sql expectations.
  charset   = "UTF8"
  collation = "en_US.UTF8"
}

resource "google_sql_user" "app" {
  name     = "onsell"
  instance = google_sql_database_instance.app.name
  password = random_password.app_db.result
}

locals {
  runtime_database_service_accounts = {
    api    = google_service_account.app.email
    worker = google_service_account.worker.email
  }
  runtime_database_usernames = {
    for workload, email in local.runtime_database_service_accounts :
    workload => trimsuffix(email, ".gserviceaccount.com")
  }
}

# IAM database users do not inherit Cloud SQL's cloudsqlsuperuser role. The
# Auth Proxy obtains short-lived login tokens for the Pod's exact GSA, while
# migration 040 grants both principals membership in the DML-only
# onsell_runtime PostgreSQL group.
resource "google_sql_user" "runtime_iam" {
  for_each = local.runtime_database_service_accounts

  name     = trimsuffix(each.value, ".gserviceaccount.com")
  instance = google_sql_database_instance.app.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

# The connection string points at the Cloud SQL Auth Proxy sidecar. Each API,
# worker, and migrator pod runs its own proxy on loopback with --private-ip;
# connector_enforcement prevents bypassing that authenticated TLS tunnel.
resource "google_secret_manager_secret" "database_url" {
  secret_id           = "${local.prefix}-database-url"
  labels              = local.labels
  deletion_protection = true
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "database_url" {
  secret = google_secret_manager_secret.database_url.id
  secret_data = format(
    "postgres://%s@127.0.0.1:5432/%s",
    urlencode(local.runtime_database_usernames.api),
    google_sql_database.app.name,
  )

  deletion_policy = "DISABLE"

  lifecycle {
    create_before_destroy = true
  }
}

# Worker authentication is a separate IAM principal and therefore requires a
# distinct passwordless URL even though both runtime principals inherit the
# same DML-only PostgreSQL group.
resource "google_secret_manager_secret" "worker_database_url" {
  secret_id           = "${local.prefix}-worker-database-url"
  labels              = local.labels
  deletion_protection = true
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "worker_database_url" {
  secret = google_secret_manager_secret.worker_database_url.id
  secret_data = format(
    "postgres://%s@127.0.0.1:5432/%s",
    urlencode(local.runtime_database_usernames.worker),
    google_sql_database.app.name,
  )

  deletion_policy = "DISABLE"
}

# The migration Job keeps the original owner login. API and worker use
# distinct automatic-IAM database users above; migration 040 grants both
# membership in the shared DML-only onsell_runtime NOLOGIN group and
# establishes matching default privileges for future objects.
resource "google_secret_manager_secret" "migration_database_url" {
  secret_id           = "${local.prefix}-migration-database-url"
  labels              = local.labels
  deletion_protection = true
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "migration_database_url" {
  secret = google_secret_manager_secret.migration_database_url.id
  secret_data = format(
    "postgres://%s:%s@127.0.0.1:5432/%s",
    google_sql_user.app.name,
    urlencode(random_password.app_db.result),
    google_sql_database.app.name,
  )

  deletion_policy = "DISABLE"
}

resource "google_secret_manager_secret_iam_member" "external_secrets_database_url_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.database_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.external_secrets.email}"
}

resource "google_secret_manager_secret_iam_member" "external_secrets_worker_database_url_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.worker_database_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.external_secrets.email}"
}

resource "google_secret_manager_secret_iam_member" "external_secrets_migration_database_url_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.migration_database_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.external_secrets.email}"
}

# ---------------------------------------------------------------------------
# Matrix database
#
# Matrix/Synapse and each mautrix bridge keep credentials and session state
# that are not reconstructable without forcing merchants to pair again. They
# therefore use a separate HA failure domain and independent credentials.

locals {
  matrix_databases = {
    synapse = {
      database  = "synapse"
      user      = "synapse"
      collation = "C"
    }
    whatsapp = {
      database  = "mautrix_whatsapp"
      user      = "mautrix_whatsapp"
      collation = "en_US.UTF8"
    }
    instagram = {
      database  = "mautrix_instagram"
      user      = "mautrix_instagram"
      collation = "en_US.UTF8"
    }
  }

  # Exact Secret Manager suffixes consumed by
  # infra/k8s/messaging/base/external-secrets.yaml. Terraform creates only the
  # containers and ESO grants; release automation populates reviewed values.
  matrix_runtime_secret_names = toset([
    "synapse-macaroon-secret-key",
    "synapse-form-secret",
    "synapse-signing-key",
    "whatsapp-as-token",
    "whatsapp-hs-token",
    "whatsapp-provisioning-shared-secret",
    "instagram-as-token",
    "instagram-hs-token",
    "instagram-provisioning-shared-secret",
  ])
}

resource "google_sql_database_instance" "matrix" {
  count            = var.enable_matrix_cloudsql ? 1 : 0
  name             = "${local.prefix}-matrix-pg"
  region           = var.region
  database_version = "POSTGRES_16"

  deletion_protection = true

  settings {
    tier                        = var.matrix_db_tier
    edition                     = "ENTERPRISE"
    availability_type           = "REGIONAL"
    deletion_protection_enabled = true
    connector_enforcement       = "REQUIRED"

    disk_type             = "PD_SSD"
    disk_size             = var.matrix_db_disk_gb
    disk_autoresize       = true
    disk_autoresize_limit = var.matrix_db_disk_gb * 5

    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
      backup_retention_settings {
        retained_backups = 14
        retention_unit   = "COUNT"
      }
    }

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.vpc.id
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
    }

    maintenance_window {
      day          = 7
      hour         = 4
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
    }

    user_labels = local.labels
  }

  depends_on = [google_service_networking_connection.psa]
}

resource "random_password" "matrix_db" {
  for_each = var.enable_matrix_cloudsql ? local.matrix_databases : {}

  length           = 32
  special          = true
  override_special = "!#%*()-_=+[]{}<>:?"
}

resource "google_sql_database" "matrix" {
  for_each = var.enable_matrix_cloudsql ? local.matrix_databases : {}

  name      = each.value.database
  instance  = google_sql_database_instance.matrix[0].name
  charset   = "UTF8"
  collation = each.value.collation
}

resource "google_sql_user" "matrix" {
  for_each = var.enable_matrix_cloudsql ? local.matrix_databases : {}

  name     = each.value.user
  instance = google_sql_database_instance.matrix[0].name
  password = random_password.matrix_db[each.key].result
}

resource "google_secret_manager_secret" "matrix_database_url" {
  for_each = var.enable_matrix_cloudsql ? local.matrix_databases : {}

  secret_id           = "${local.prefix}-matrix-${each.key}-database-url"
  labels              = local.labels
  deletion_protection = true
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "matrix_database_url" {
  for_each = var.enable_matrix_cloudsql ? local.matrix_databases : {}

  secret = google_secret_manager_secret.matrix_database_url[each.key].id
  secret_data = format(
    "postgres://%s:%s@127.0.0.1:5432/%s",
    google_sql_user.matrix[each.key].name,
    urlencode(random_password.matrix_db[each.key].result),
    google_sql_database.matrix[each.key].name,
  )

  deletion_policy = "DISABLE"
}

resource "google_secret_manager_secret_iam_member" "external_secrets_matrix_database_url_access" {
  for_each  = google_secret_manager_secret.matrix_database_url
  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.external_secrets.email}"
}

resource "google_secret_manager_secret" "matrix_runtime" {
  for_each = var.enable_matrix_cloudsql ? local.matrix_runtime_secret_names : toset([])

  secret_id           = "${local.prefix}-matrix-${each.value}"
  labels              = local.labels
  deletion_protection = true
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_iam_member" "external_secrets_matrix_runtime_access" {
  for_each = google_secret_manager_secret.matrix_runtime

  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.external_secrets.email}"
}

# ---------------------------------------------------------------------------
# Memorystore for Valkey
#
# PostGIS and pgvector are NOT provisioned here — they are per-database
# extensions. After the first apply, from a pod or the SQL proxy:
#   CREATE EXTENSION IF NOT EXISTS postgis;
#   CREATE EXTENSION IF NOT EXISTS vector;
# Cloud SQL for PostgreSQL supports both (pgvector 0.8.1), which is why the
# app database did not need to stay self-hosted.

resource "google_memorystore_instance" "cache" {
  instance_id = "${local.prefix}-valkey"
  location    = var.region

  shard_count    = 1
  replica_count  = var.valkey_replica_count
  node_type      = var.valkey_node_type
  engine_version = "VALKEY_7_2"

  # See variables.tf — CLUSTER_DISABLED is load-bearing for pub/sub, not taste.
  mode = var.valkey_mode

  desired_auto_created_endpoints {
    network    = google_compute_network.vpc.id
    project_id = var.project_id
  }

  zone_distribution_config {
    mode = "SINGLE_ZONE"
    zone = var.zone
  }

  # Disposable cache and typing pub/sub only. Sessions, security rate limits,
  # and provider-token state use the authenticated, noeviction instance below.
  engine_configs = {
    maxmemory-policy = "allkeys-lru"
  }

  authorization_mode      = "AUTH_DISABLED" # private PSC endpoint, no public path
  transit_encryption_mode = "TRANSIT_ENCRYPTION_DISABLED"

  # Persistence shortens cache warm-up after maintenance but is not relied on
  # for correctness.
  # NOTE: the Memorystore API accepts exactly ONE changed field per update
  # request ("exactly 1 update_mask field must be specified"). This landed in
  # its own apply, separate from deletion_protection_enabled. If you ever
  # change two Valkey fields at once, expect a 400 and split the change.
  persistence_config {
    mode = "RDB"
    rdb_config {
      rdb_snapshot_period = "TWELVE_HOURS"
    }
  }

  deletion_protection_enabled = true

  labels = local.labels

  depends_on = [
    google_network_connectivity_service_connection_policy.memorystore,
  ]
}

# Security/session plane. STANDARD_SMALL carries the production SLA; one
# replica is distributed across zones. IAM_AUTH uses short-lived access tokens,
# TLS authenticates the server, noeviction fails writes explicitly rather than
# silently discarding session/idempotency state, and AOF limits restart loss.
resource "google_memorystore_instance" "security" {
  instance_id = "${local.prefix}-valkey-security"
  location    = var.region

  shard_count    = 1
  replica_count  = 1
  node_type      = "STANDARD_SMALL"
  engine_version = "VALKEY_7_2"
  mode           = "CLUSTER_DISABLED"

  desired_auto_created_endpoints {
    network    = google_compute_network.vpc.id
    project_id = var.project_id
  }

  zone_distribution_config {
    mode = "MULTI_ZONE"
  }

  engine_configs = {
    maxmemory-policy = "noeviction"
  }

  authorization_mode      = "IAM_AUTH"
  transit_encryption_mode = "SERVER_AUTHENTICATION"

  persistence_config {
    mode = "AOF"
    aof_config {
      append_fsync = "EVERY_SEC"
    }
  }

  deletion_protection_enabled = true
  labels                      = local.labels

  depends_on = [
    google_network_connectivity_service_connection_policy.memorystore,
  ]
}

# The provider does not expose instance-level IAM resources for Memorystore.
# These project IAM grants are therefore constrained to the exact durable
# instance name. The disposable AUTH_DISABLED cache is intentionally excluded.
resource "google_project_iam_member" "security_valkey_access" {
  for_each = {
    api    = google_service_account.app.email
    worker = google_service_account.worker.email
  }

  project = var.project_id
  role    = "roles/memorystore.dbConnectionUser"
  member  = "serviceAccount:${each.value}"

  condition {
    title       = "connect_to_onsell_security_valkey"
    description = "Only the durable session/security Valkey instance."
    expression  = "resource.name == 'projects/${var.project_id}/locations/${var.region}/instances/${local.prefix}-valkey-security'"
  }

  depends_on = [google_memorystore_instance.security]
}

locals {
  cache_endpoint_connections = [
    for connection in flatten([
      for endpoint in google_memorystore_instance.cache.endpoints : [
        for group in endpoint.connections :
        group.psc_auto_connection
      ]
    ]) : connection if connection.connection_type == "CONNECTION_TYPE_PRIMARY"
  ]
  security_endpoint_connections = [
    for connection in flatten([
      for endpoint in google_memorystore_instance.security.endpoints : [
        for group in endpoint.connections :
        group.psc_auto_connection
      ]
    ]) : connection if connection.connection_type == "CONNECTION_TYPE_PRIMARY"
  ]
  security_server_ca = join("\n", flatten([
    for authority in google_memorystore_instance.security.managed_server_ca : [
      for chain in authority.ca_certs : chain.certificates
    ]
  ]))
}

resource "google_secret_manager_secret" "redis" {
  for_each = toset([
    "redis-cache-url",
    "redis-security-url",
    "redis-security-ca",
  ])

  secret_id           = "${local.prefix}-${each.value}"
  labels              = local.labels
  deletion_protection = true
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "redis_cache_url" {
  secret = google_secret_manager_secret.redis["redis-cache-url"].id
  secret_data = format(
    "redis://%s:%d",
    local.cache_endpoint_connections[0].ip_address,
    local.cache_endpoint_connections[0].port,
  )

  deletion_policy = "DISABLE"
}

# IAM access tokens are deliberately absent from this URL: they expire within
# an hour and must be obtained/refreshed through Workload Identity by the
# client. The CA is a separate secret so clients can configure TLS explicitly.
resource "google_secret_manager_secret_version" "redis_security_url" {
  secret = google_secret_manager_secret.redis["redis-security-url"].id
  secret_data = format(
    "rediss://%s:%d",
    local.security_endpoint_connections[0].ip_address,
    local.security_endpoint_connections[0].port,
  )

  deletion_policy = "DISABLE"
}

resource "google_secret_manager_secret_version" "redis_security_ca" {
  secret          = google_secret_manager_secret.redis["redis-security-ca"].id
  secret_data     = local.security_server_ca
  deletion_policy = "DISABLE"
}

resource "google_secret_manager_secret_iam_member" "external_secrets_redis_access" {
  for_each  = google_secret_manager_secret.redis
  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.external_secrets.email}"
}
