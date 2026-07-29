# Onsell infrastructure

Private GCP infrastructure-as-code for Onsell. This repository owns the
production Terraform state contract, cloud IAM, GKE, Cloud SQL, Memorystore,
Artifact Registry, storage, DNS, CDN, observability, budgets, and API edge.
Application code belongs in `Pilgrim-Xzed/onsell-backend`; Kubernetes desired
state belongs in `Pilgrim-Xzed/onsell-gitops`.

## Layout

- `terraform/environments/production` — the existing production root. Its
  resource addresses and GCS backend are unchanged.
- `scripts/bootstrap-state.sh` — one-time state-bucket bootstrap; do not rerun
  for the existing production project.
- `docs/infrastructure-readiness.md` — live remediation and release gates.

## Safe workflow

```bash
cd terraform/environments/production
terraform init -reconfigure
terraform fmt -check -recursive
terraform validate
terraform plan
```

The state backend remains
`gs://onsell-tfstate-chrome-oven-503818-h4/prod/default.tfstate`. Saved plans,
state, real `terraform.tfvars`, and cloud credentials must never enter Git or
CI artifacts.

Production automation is manual, OIDC-only, and protected by the GitHub
`production` environment. Configure these environment variables before using
it:

- `GCP_WORKLOAD_IDENTITY_PROVIDER`
- `GCP_TERRAFORM_SERVICE_ACCOUNT`
- `TF_VAR_AUTHORIZED_NETWORKS` as Terraform-compatible JSON
- `TF_VAR_CDN_FILL_GRANT` as `true` or `false`

No workflow applies on push.
