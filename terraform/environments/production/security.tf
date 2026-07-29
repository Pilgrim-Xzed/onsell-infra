# Cloud Armor policy attached by the onsell-api GCPBackendPolicy.
#
# WAF signatures begin in preview mode: webhook bodies and long-lived desktop
# traffic must be observed before a deny action is promoted. Preview still
# emits match telemetry while the final rule keeps production traffic flowing.

resource "google_compute_security_policy" "api" {
  name        = "${local.prefix}-api-armor"
  description = "Onsell API edge WAF; preview rules require tuning before enforcement"
  type        = "CLOUD_ARMOR"

  rule {
    action      = "deny(403)"
    priority    = 1000
    preview     = true
    description = "Preview OWASP SQL injection signatures"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable')"
      }
    }
  }

  rule {
    action      = "deny(403)"
    priority    = 1010
    preview     = true
    description = "Preview OWASP cross-site scripting signatures"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable')"
      }
    }
  }

  rule {
    action      = "deny(403)"
    priority    = 1020
    preview     = true
    description = "Preview OWASP local file inclusion signatures"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('lfi-v33-stable')"
      }
    }
  }

  rule {
    action      = "deny(403)"
    priority    = 1030
    preview     = true
    description = "Preview OWASP remote code execution signatures"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('rce-v33-stable')"
      }
    }
  }

  rule {
    action      = "deny(403)"
    priority    = 1040
    preview     = true
    description = "Preview OWASP scanner detection signatures"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('scannerdetection-v33-stable')"
      }
    }
  }

  rule {
    action      = "allow"
    priority    = 2147483647
    description = "Default allow while preview signatures are tuned"

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

output "api_cloud_armor_policy" {
  description = "Set spec.default.securityPolicy to this in the API GCPBackendPolicy."
  value       = google_compute_security_policy.api.name
}
