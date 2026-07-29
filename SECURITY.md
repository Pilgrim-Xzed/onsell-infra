# Security

Report vulnerabilities through GitHub's private security-advisory flow, not a
public issue. Never attach Terraform plans/state, cloud credentials, secret
versions, service-account keys, or production logs.

Terraform state is private and may contain generated credentials even when the
configuration marks them sensitive.
