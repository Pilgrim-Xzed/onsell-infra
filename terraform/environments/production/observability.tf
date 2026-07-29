# Cost ceiling, log-volume control, and the alerts that make this operable.
#
# Everything in this file is free or near-free. The expensive mistakes in a
# small GCP estate are not the resources you chose — they are the ones nobody
# noticed: a log pipeline that quietly exceeds the free tier, a disk that
# auto-grows and never shrinks, a workload that scales up and stays up.

variable "alert_email" {
  description = "Where budget and health alerts go."
  type        = string
  default     = "saeed@onsell.ai"
}

variable "monthly_budget_usd" {
  description = <<-EOT
    Budget threshold in USD. Alerts only — GCP budgets never stop spend.

    Sized at roughly 1.6x the modelled steady-state bill so normal growth does
    not cry wolf, but a runaway (a stuck Autopilot scale-up, a log flood, an
    accidental HA toggle) trips it well before the invoice.
  EOT
  type        = number
  default     = 300
}

resource "google_monitoring_notification_channel" "email" {
  display_name = "Onsell ops"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Budget. Requires billing-account permissions; if the apply 403s here, the
# rest of the file still applies — set the budget by hand in the console.

resource "google_billing_budget" "monthly" {
  billing_account = var.billing_account_id
  display_name    = "onsell-${var.project_id}"

  budget_filter {
    projects               = ["projects/${data.google_project.this.number}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_usd)
    }
  }

  # 50% and 90% are early warnings; 100% forecasted catches a trend before it
  # lands, which is the one that actually saves money.
  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.email.id]
    disable_default_iam_recipients   = false
  }
}

# ---------------------------------------------------------------------------
# Log volume.
#
# Cloud Logging bills $0.50/GiB above 50 GiB/project/month. The study flagged
# Synapse as notoriously verbose and load-balancer request logs as the one
# thing that gets you near the ceiling at this traffic. Excluding them is free
# and reversible; paying for them is neither.

resource "google_logging_project_exclusion" "lb_requests" {
  name        = "exclude-lb-request-logs"
  description = "HTTP LB request logs — high volume, low value at this scale"
  filter      = "resource.type=\"http_load_balancer\" AND severity<ERROR"
}

resource "google_logging_project_exclusion" "k8s_noise" {
  name        = "exclude-k8s-info-noise"
  description = "INFO-level kubelet/system chatter; WARNING and above are kept"
  filter      = <<-EOT
    resource.type="k8s_node" AND severity<WARNING
  EOT
}

# ---------------------------------------------------------------------------
# Health alerts. The money database and the thing in front of it.

resource "google_monitoring_alert_policy" "sql_cpu" {
  display_name = "Cloud SQL CPU > 85% (5m)"
  combiner     = "OR"

  conditions {
    display_name = "app-pg cpu"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/cpu/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.85
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
  depends_on            = [google_project_service.apis]
}

# Cloud SQL storage auto-grows and never shrinks, so "nearly full" is a
# spending alert as much as an availability one.
resource "google_monitoring_alert_policy" "sql_disk" {
  display_name = "Cloud SQL disk > 80%"
  combiner     = "OR"

  conditions {
    display_name = "app-pg disk"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND metric.type = \"cloudsql.googleapis.com/database/disk/utilization\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]
  depends_on            = [google_project_service.apis]
}

# The CDN returns 403 to unsigned requests by design, so a naive uptime check
# would flap. Check that TLS terminates and the LB answers at all.
resource "google_monitoring_uptime_check_config" "cdn" {
  display_name = "images.onsell.ai reachable"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path         = "/"
    port         = 443
    use_ssl      = true
    validate_ssl = true
    # 403 is the correct answer to an unsigned request — treat it as healthy.
    accepted_response_status_codes {
      status_value = 403
    }
    accepted_response_status_codes {
      status_class = "STATUS_CLASS_2XX"
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.cdn_domain
    }
  }

  depends_on = [google_project_service.apis]
}
