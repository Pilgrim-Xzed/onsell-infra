# Infrastructure readiness and remediation record

**Reviewed and remediated:** 2026-07-29
**Project:** `chrome-oven-503818-h4`
**Region:** `africa-south1`

## Decision

The GCP foundation and the repository's deployment contracts are now
substantially safer, but the product is intentionally **not deployed and not
ready for production traffic**. The remaining release gates require owner
inputs or recurring spend; they cannot be safely guessed.

No Onsell API, worker, migrator, Synapse, or bridge workload is running in the
live cluster. Production manifests fail closed until real image digests,
provider secret versions, a GitOps repository URL, and the optional Matrix
data plane are supplied.

## Live controls verified after remediation

| Control | Live state |
|---|---|
| GCP project | Every operator command pins `chrome-oven-503818-h4`; the local gcloud default is a different project |
| GKE | Autopilot `1.35.6-gke.1127000`, `REGULAR` channel, private nodes, Workload Identity enabled |
| Kubernetes API access | Master authorized networks enabled for the current operator `/32` |
| Application Cloud SQL | PostgreSQL 16, `REGIONAL`, `RUNNABLE`, backups and PITR enabled |
| SQL transport | `connectorEnforcement=REQUIRED`, `sslMode=ENCRYPTED_ONLY`, and automatic IAM database authentication enabled |
| SQL deletion protection | Enabled in both the resource and instance settings |
| Runtime identities | Separate API, worker, migrator, and External Secrets Google service accounts; API/worker each have a distinct Cloud SQL IAM database user |
| Database schema | All 40 migrations applied to the pristine live database; API and worker automatic-IAM login and DML-only privileges verified end to end |
| Secret access | No application identity has project-wide Secret Manager access; External Secrets has exact secret-level grants |
| Media access | API object administration is scoped to the media bucket; public access prevention and uniform bucket-level access are enabled |
| Secret payload boundary | Separate API, worker, migration-database, and CDN-signing versions exist; obsolete password-bearing API URL versions were destroyed; provider, Matrix, and durable-Valkey values remain deliberately unpopulated |
| Cluster workloads | Only GKE system workloads, Argo CD, and ExternalDNS are installed; there are no Onsell Argo Applications or product workloads |

Secret values were never printed or inspected. The migration URL was streamed
directly from Secret Manager into a short-lived Kubernetes Secret for the
one-shot migration and verification Jobs; the namespace and every temporary
object were deleted immediately afterward.

## Repository and runtime blockers fixed

### Database and payment correctness

- Added a frozen `000_baseline.sql`.
- Made the migrator apply only ordered, ledger-tracked migrations.
- Added a disposable PostgreSQL 16/PostGIS/pgvector harness that proves a
  fresh database can run the full migration chain and rerun idempotently.
- Split the PostgreSQL schema-owner/migrator login from distinct API and worker
  automatic-IAM database users. Both inherit a NOLOGIN DML group; migration
  040 enforces future-object defaults and the no-DDL boundary.
- Added migration `039_payment_webhook_retry.sql`.
- Made payment webhook processing leased, retryable, dead-lettered, and
  operator-replayable rather than acknowledging transient failures forever.

### Runtime health and data-store boundaries

- Added API `/api/v1/livez` and `/api/v1/readyz`.
- Added worker `/livez` and `/readyz` on port `3001`, including per-lane
  starting, degraded, stale, and stopping states.
- Split durable session/security Redis from disposable cache/typing Redis.
- Added IAM access-token refresh and managed-CA TLS verification for the
  durable Valkey path.
- Security rate limits now fail closed when their durable store is unavailable.

### Desktop production contract

- Packaged Electron builds default to `https://api.k8s.onsell.ai`.
- Plain HTTP is accepted only for loopback development.
- Production server selection is locked unless an explicit support override is
  enabled.
- Bearer tokens remain in Electron main and use OS-backed secure storage; the
  renderer never receives them.

### Infrastructure and GitOps contracts

- Cloud SQL now requires the Auth Proxy/language connector.
- Database URLs use the proxy's loopback listener rather than the private
  instance address.
- Project-wide Secret Manager and object-storage grants were removed from the
  application identity.
- Workload Identity bindings target exact Kubernetes service accounts in
  `onsell-app`, `external-secrets`, and—when enabled—`onsell-messaging`.
- Core app manifests include API, worker, protected migration Job, immutable
  images, probes, disruption budgets, autoscaling, topology spread, restricted
  security contexts, default-deny networking, Gateway/HTTPRoute, Cloud Armor,
  and health-check policies.
- Platform manifests include restricted Argo CD projects and a pinned External
  Secrets Operator release.
- A separate, fail-closed messaging package defines Synapse,
  mautrix-whatsapp, and mautrix-instagram without reusing credential-bearing
  local runtime files.

## Remaining production gates

### Owner input: no safe automatic value exists

1. **Populate Secret Manager versions.** Provider, Matrix, and durable-Valkey
   containers exist or are declared, but values must come from the real
   provider accounts. Empty secrets are a deliberate release failure.
2. **Build and publish images.** Artifact Registry has no release artifacts.
   CI must build API, worker, and migrator from one commit, scan and sign them,
   then place immutable `sha256` digests in GitOps.
3. **Connect the private GitOps repository.** The reviewed manifests use
   `https://github.com/Pilgrim-Xzed/onsell-gitops.git`; configure Argo with a
   read-only GitHub App or deploy key supplied out of band.
4. **Rotate tracked Matrix credentials and clean history.** The current root
   history contains a signing key, generated bridge configs/logs, and runtime
   media. Rotation must precede a coordinated clean-history export.
5. **Choose the customer media contract.** CDN-origin objects are private and
   unsigned public URLs return `403`. Implement signed URLs/cookies at read
   time or isolate a deliberately public immutable-catalog bucket, then require
   a `200` canary.
6. **Supply alert destinations and ownership.** Pager/email channels, service
   owners, SLO approval, and incident escalation policy are organizational
   inputs.
7. **Supply desktop signing identities.** macOS Developer ID/notarization and
   Windows signing credentials are required before an installer release.

### Explicit cost approval

The unapplied Terraform plan contains no destruction, but includes material
recurring cost:

| Resource | Approximate recurring cost |
|---|---:|
| Replicated Standard Small durable Valkey | US$208.05/month |
| Valkey AOF persistence | roughly US$3–5/month |
| Cloud Armor Standard policy/rules | roughly US$11/month plus requests |
| Gateway forwarding rules when Kubernetes owns the edge | roughly US$36.50/month for HTTP + HTTPS |
| Optional regional Matrix Cloud SQL | roughly US$98/month when enabled |

The durable Valkey, public API edge, and Matrix database remain unapplied until
that spend is approved. The existing low-cost nano Valkey remains only for
disposable cache/typing state; it must not hold production sessions or
security counters.

## Credential-bearing history containment

`scripts/verify-repository-safety.sh` intentionally fails against the current
root history. Do not publish or split repositories by copying this history.

Required incident sequence:

1. Freeze publishing of the root history.
2. Inventory every copied clone, build cache, and remote.
3. Rotate/revoke Matrix and other credentials present in history.
4. Export reviewed source into new repositories with clean history.
5. Remove generated configs, signing keys, logs, media, state, and plans.
6. Enable secret scanning and push protection.
7. Coordinate a history rewrite only after backups and fresh-clone
   instructions are ready.

Terraform state remains in its private GCS backend. Saved local plan files are
ignored and must never be attached to tickets or committed.

## Recommended repository ownership

| Repository | Ownership |
|---|---|
| Existing `onsell` | Electron/merchant clients and landing product |
| Private `onsell-backend` | Backend source plus API, worker, and migrator images from one revision |
| Private `onsell-infra` | Terraform foundations, IAM, managed stores, DNS, and edge |
| Private `onsell-gitops` | Argo CD, Kustomize overlays, immutable image digests, and messaging desired state |

Do not create one repository per provider. Glovo, Talabat, and Chowdeck are
currently consent/connection-request records, not implemented runtime
adapters. Synapse and mautrix should remain digest-pinned upstream components
unless Onsell maintains a fork.

## Validation evidence

- Terraform formatting and provider-backed validation pass.
- The current Matrix-off Terraform plan is `14 add, 0 change, 0 destroy`; the
  optional Matrix-on plan is `63 add, 0 change, 0 destroy`. Cost-bearing
  resources remain unapplied.
- A clean PostgreSQL 16 database runs all 40 migrations and an idempotent
  second pass.
- Backend lint and the route-permission manifest pass.
- Backend production build passes.
- Backend tests pass: 24 files, 341 tests.
- Desktop lint/check, TypeScript, production build, and 237 tests pass.
- Core and messaging Kustomize packages render and pass schema/static-policy
  checks.
- `RELEASE_READY=1` correctly fails while repository URLs, image digests,
  identities, and external secret versions are placeholders.

## Go-live sequence

1. Approve the durable Valkey/API-edge budget and apply the reviewed plan.
2. Create clean backend, infrastructure, and GitOps repositories.
3. Populate provider secrets; do not put values in Terraform or Git.
4. Build, scan, sign, attest, and push the three backend images.
5. Replace GitOps repository and digest placeholders.
6. Install/sync External Secrets and verify every required target Secret.
7. Run the migrator through the Cloud SQL Auth Proxy.
8. Deploy API and worker; verify live/readiness and rollback.
9. Attach Gateway, certificate, DNS, and Cloud Armor; run authenticated smoke
   and SSE tests.
10. If social inbox is enabled, approve Matrix Cloud SQL, rotate credentials,
    deploy messaging, and prove a restore that preserves paired sessions.
11. Run payment retry/reconciliation and Cloud SQL PITR drills.
12. Release only signed/notarized desktop artifacts through a staged channel.

Use expand/contract database migrations. An application rollback must never
automatically reverse a production schema migration.
