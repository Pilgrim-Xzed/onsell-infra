# Onsell infrastructure — GKE Autopilot (africa-south1)

Terraform for the **Balanced** configuration in
[`docs/gke-autopilot-cost-study.md`](../../../docs/gke-autopilot-cost-study.md).
Shared bridges — per-business bridges are not built and should not be
(the cost crossover is at merchant #2, and the Synapse restart makes
onboarding an outage).

## Live project status

Billing is linked and the foundation is live in `chrome-oven-503818-h4`.
Cloud SQL, GKE, networking, buckets, DNS, and the low-cost disposable cache
already exist. Do not run an unreviewed full apply: the remaining plan includes
the replicated durable Valkey and public API edge, which add material recurring
cost. The reconciled Matrix-off plan is `14 add, 0 change, 0 destroy`; Matrix
remains conditional and disabled.

## Watch the active project

`gcloud config` may point at a different project. The one-time
`../../../scripts/bootstrap-state.sh` command passes `--project` explicitly
and Terraform pins `project_id`. Do not drop the flag.

## Apply

```bash
terraform init -reconfigure     # use the existing remote state
terraform plan -out=tfplan      # read it
terraform apply tfplan
```

Do not rerun `../../../scripts/bootstrap-state.sh` for the existing production
project. It exists only to create a state bucket for a first installation.

Then wire kubectl:

```bash
gcloud container clusters get-credentials onsell-autopilot \
  --region africa-south1 --project chrome-oven-503818-h4

```

Do not bootstrap extensions through an API or worker `DATABASE_URL`; those IAM
principals are deliberately DML-only. `000_baseline.sql` owns the required
`postgis`, `pg_trgm`, and `vector` extension creation and must run through the
protected migrator Job, whose Cloud SQL Auth Proxy uses
`onsell-migration-database-url`.

## What it creates

| Resource | Notes |
|---|---|
| VPC + GKE/PSC subnets | VPC-native, secondary ranges for pods and services |
| GKE Autopilot cluster | Private nodes, Workload Identity, REGULAR channel |
| App Cloud SQL PostgreSQL 16 | Private IP, connector-only, automatic IAM users for API/worker, owner isolated to migrations, API + Terraform deletion protection, **PITR on** |
| Matrix Cloud SQL PostgreSQL 16 | Conditional, separate REGIONAL failure domain, three DB/users, private + connector-only, **PITR on** |
| Disposable cache Valkey | Existing 1-shard `SHARED_CORE_NANO`, `allkeys-lru`, preserved as a low-cost cache |
| Security/session Valkey | `STANDARD_SMALL` + replica, MULTI_ZONE, IAM auth, TLS, noeviction, AOF, deletion protection |
| Runtime identities | Separate API, worker and migrator GSAs plus `onsell-external-secrets`; Matrix-on adds exact Synapse/WhatsApp/Instagram KSA↔GSA bindings |
| Cloud NAT | Private nodes → Anthropic, Monnify, WhatsApp |
| Artifact Registry | With cleanup policies (untagged images accumulate) |
| GCS buckets | `media` (CDN origin), `desktop-updates` |
| Secret Manager | External provider containers plus distinct API, worker, migration and Matrix DB/Redis contracts; Matrix-on adds nine messaging secret containers |
| API edge | Dedicated `onsell-api-ingress-ip`, `api.k8s.onsell.ai` A record, DNS-authorized cert map `onsell-api-production`, Cloud Armor policy `onsell-api-armor` |
| CDN edge | Existing `onsell-ingress-ip` remains dedicated to media CDN :80/:443 |

## What it deliberately does *not* create

- **Matrix by default.** `enable_matrix_cloudsql=false` avoids spending on an
  unused REGIONAL database. Enabling it provisions the durable data plane, but
  you must still populate the nine Matrix runtime secrets, patch the messaging
  manifests from the Terraform identity/connection outputs, deploy the
  Synapse/mautrix proxy sidecars, and prove a restore before onboarding
  merchants.
- **Managed Prometheus** — off. Unbounded ingestion is ~$104/mo at 10k series
  on a 15s scrape, more than the entire pod bill. Opt in deliberately.
- **The Gateway / forwarding rule** — belongs with the k8s manifests. Budget
  $18.25/mo per rule, ×2 if you want an HTTP→HTTPS redirect. There is no
  Cloud Run domain-mapping escape hatch on Autopilot.
- **Kubernetes workloads** — this is infrastructure only. Versioned,
  fail-closed manifests live in the private
  `Pilgrim-Xzed/onsell-gitops` repository; Terraform does not deploy them.
  GitOps promotion must replace identity and image-digest placeholders before
  Argo is allowed to sync.

## Cost (africa-south1, verified against the Cloud Billing Catalog API)

| Line | $/mo |
|---|---:|
| Cloud SQL app, 1 vCPU / 3.75 GiB / 20 GB, REGIONAL | ~98 |
| Matrix Cloud SQL, same REGIONAL base tier | ~98 when enabled |
| Disposable Valkey `SHARED_CORE_NANO` | ~25.55 |
| Security Valkey, 2 × `STANDARD_SMALL` | ~208.05 |
| Security Valkey AOF persistence | roughly 3–5 |
| Autopilot pods (6 pods, §A of the study) | ~67 @10 users, ~84 @20 |
| API Gateway :80/:443 forwarding rules | ~36.50 once the Gateway owns the IP |
| Cloud Armor Standard | ~11 for one policy + six rules, plus $0.75/million requests |
| GKE management fee | $73, offset by the $74.40 free-tier credit |
| **Core subtotal, Matrix off** | **~$446–466/mo before NAT, CDN edge, logs and traffic** |
| **Core subtotal, Matrix on** | **~$544–564/mo before NAT, CDN edge, logs and traffic** |

The durable Valkey line is intentionally much larger than the former mixed
nano design: Google documents `SHARED_CORE_NANO` as development/test only,
while `STANDARD_SMALL` is $0.1425/node-hour in Johannesburg. Two nodes cost
$208.05 at 730 hours, before AOF. **The free-tier credit is per BILLING
ACCOUNT, not per cluster** — a staging cluster pays the full $73.

## Runtime and rollout contracts

1. **Cloud SQL URLs are loopback URLs.** API, worker and migrator pods must run
   a Cloud SQL Auth Proxy sidecar on `127.0.0.1:5432` with `--private-ip`.
   API and worker additionally use `--auto-iam-authn`; the migrator uses the
   isolated owner credential. Connector enforcement rejects every direct
   private-IP database connection.
2. **Deploy all four Redis contracts atomically.** The backend now supports
   `REDIS_SECURITY_URL`, `REDIS_SECURITY_AUTH_MODE=iam`,
   `REDIS_SECURITY_CA`, and `REDIS_CACHE_URL`. The security URL intentionally
   contains no password: the client obtains and refreshes short-lived IAM
   access tokens through Workload Identity and verifies the managed CA.
3. **`CLUSTER_DISABLED` is load-bearing.** Ordinary Redis pub/sub is used for
   typing fan-out; cluster mode would silently shard delivery.
4. **Keep `authorized_networks` narrow.** The live control plane currently
   permits the operator's explicit `/32`; the example remains deny-all. Update
   the value when the office/VPN egress changes and never use `0.0.0.0/0`.
5. **The API hostname is Terraform-owned.** ExternalDNS watches Service and
   Ingress, not Gateway/HTTPRoute, so it must not also claim
   `api.k8s.onsell.ai`.
6. **Attach `onsell-api-armor` before public traffic.** Its SQLi, XSS, LFI,
   RCE and scanner signatures intentionally start in preview. Review Cloud
   Armor match telemetry against payment/provider webhooks, tune exclusions,
   then promote rules individually; do not bulk-disable preview.
7. **External Secrets uses its own identity.** Annotate
   `external-secrets/external-secrets` with the
   `external_secrets_service_account` output. It receives accessor bindings on
   the enumerated app, DB, Redis, Matrix and CDN secrets only—never a
   project-wide Secret Manager role. API, worker and migrator identities do
   not read Secret Manager directly; they consume only the Kubernetes Secrets
   materialized by External Secrets.
8. **Database ownership is migration-only.** The migration secret retains the
   `onsell` owner login. API and worker have separate passwordless
   `CLOUD_IAM_SERVICE_ACCOUNT` database users and separate URL secrets. Both
   inherit the `onsell_runtime` NOLOGIN group; migration 040 grants that group
   DML/schema usage and default privileges while denying schema creation and
   migration-ledger writes.
9. **Matrix is an all-or-nothing conditional contract.**
   `enable_matrix_cloudsql=true` creates the dedicated instance, three
   databases/users and loopback URL secrets, plus GSAs bound exactly to
   `onsell-messaging/synapse`, `onsell-messaging/mautrix-whatsapp`, and
   `onsell-messaging/mautrix-instagram`. It also creates the nine
   deletion-protected secret containers referenced by the messaging
   `ExternalSecret` resources. Terraform deliberately creates no versions for
   signing, macaroon, form, appservice, or provisioning secrets; populate and
   cross-check those values before enabling the Argo application.
