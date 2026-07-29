# Onsell on GKE Autopilot — Cost Study

**Basis:** europe-west2 (London), USD/month, 730 h/month, list price, no CUDs. NGN at ₦1,600/USD. All Autopilot pods respect the **bursting-cluster** floor (50 mCPU / 52 MiB / 10 MiB ephemeral per container), the **1:1–1:6.5 vCPU:GiB ratio**, and carry no 0.25-vCPU rounding — a cluster created today runs GKE 1.35.x (Regular channel default), well past the 1.30.2-gke.1394000 bursting threshold.

**Rates used throughout (verified against Google's published monthly columns, which reconcile to the hour × 730 exactly):**

| SKU | $/hr | $/month |
|---|---:|---:|
| Autopilot general-purpose vCPU | 0.0573 | 41.8290 |
| Autopilot memory (GiB) | 0.0063421 | 4.629733 |
| Autopilot ephemeral SSD (GiB) | 0.0001789 | 0.130597 |
| Autopilot Spot vCPU / memory | 0.0172 / 0.0019026 | 12.5560 / 1.388898 |
| Cluster management fee | 0.10 | 73.00 |

**The headline, before any detail:** infrastructure is not your problem. The Balanced build runs **$239/mo at 10 merchants and $290/mo at 20**. The AI line at the same scale is **$131–$389/mo**, and the plan catalog in `billing.ts` is priced below its own AI cost at every paid tier. You could cut infrastructure to zero and still lose money per merchant.

---

## A. Full pod inventory on Autopilot

Every service is a Deployment on Autopilot. **There is no Cloud Run in this architecture.** Two lines in the research and in `docs/gcp-deployment-architecture.md` were priced as Cloud Run and are replaced here:

| Was (doc §6a/6b) | Now | Substitution |
|---|---|---|
| Cloud Run — backend, ~1.2 inst, 1 vCPU/1 GiB, 19M req → **$84/mo** | `next-backend` Deployment, 2 × 250m/512Mi | **$25.81/mo** |
| Cloud Run — worker, min-instances 1, CPU always on → **$55/mo** | `worker` Deployment, 1 × 150m/512Mi | **$8.72/mo** |

Autopilot bills the *request*, not the request count. The 19.9M req/mo that dominated the Cloud Run bill costs nothing extra here — it only has to fit in the CPU request. That single change removes ~$139/mo of the doc's Cloud Run estimate and replaces it with $34.53 of pods.

### A.1 — Balanced sizing at 10 merchants

| Pod | Repl | CPU req | Mem req | Eph req | Ratio | $/pod/mo | $/mo |
|---|---:|---:|---:|---:|---:|---:|---:|
| `next-backend` | 2 | 250m | 512Mi | 1Gi | 1:2.00 | 12.90 | 25.81 |
| `worker` | 1 | 150m | 512Mi | 1Gi | 1:3.33 | 8.72 | 8.72 |
| `synapse` | 1 | 300m | 1024Mi | 2Gi | 1:3.33 | 17.44 | 17.44 |
| `mautrix-whatsapp` | 1 | 120m | 768Mi | 1Gi | 1:6.25 | 8.62 | 8.62 |
| `mautrix-meta` | 1 | 100m | 384Mi | 1Gi | 1:3.75 | 6.05 | 6.05 |
| **Total** | **6** | **1,170m** | **3,712Mi** | **7Gi** | | | **66.64** |

Check: 25.81 + 8.72 + 17.44 + 8.62 + 6.05 = **66.64**. ✅

### A.2 — Balanced sizing at 20 merchants (delta only)

| Pod | Repl | CPU req | Mem req | Eph req | Ratio | $/pod/mo | $/mo | Δ vs 10 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `next-backend` | 2 | 350m | 640Mi | 1Gi | 1:1.79 | 17.66 | 35.33 | +9.52 |
| `worker` | 1 | 150m | 512Mi | 1Gi | 1:3.33 | 8.72 | 8.72 | 0.00 |
| `synapse` | 1 | 350m | 1280Mi | 2Gi | 1:3.57 | 20.69 | 20.69 | +3.25 |
| `mautrix-whatsapp` | 1 | 180m | 1024Mi | 1Gi | 1:5.56 | 12.29 | 12.29 | +3.67 |
| `mautrix-meta` | 1 | 120m | 512Mi | 1Gi | 1:4.17 | 7.46 | 7.46 | +1.41 |
| **Total** | **6** | **1,500m** | **4,608Mi** | **7Gi** | | | **84.49** | **+17.85** |

Check: 35.33 + 8.72 + 20.69 + 12.29 + 7.46 = **84.49**; 84.49 − 66.64 = **17.85**. ✅

**Doubling merchant count costs $17.85/month in pods.** That is the whole scaling story at this size.

### A.3 — Why each request is what it is

| Pod | Modelled actual (10→20) | Request | Why |
|---|---|---|---|
| `next-backend` | 115→206 mCPU total; 200–280 MiB RSS steady, 350–450 MiB peak | 2×250m/512Mi → 2×350m/640Mi | **Sized up over steady RSS**: invoice-PDF generation dynamically imports `sharp` (libvips, +40–60 MiB) and holds PDF buffers. 512Mi covers the 450 MiB peak; memory is not compressible, so a request at steady RSS would OOMKill during invoice runs. CPU is per-replica ~58→103 mCPU, so 250m/350m leaves burst headroom for the 5s board poll. |
| `worker` | 35→50 mCPU; 200–280 MiB RSS | 150m/512Mi flat | Merchant-count-independent: 4.3 q/s of loop polling regardless of tenancy. Runs TypeScript via `tsx`, so ~60–80 MiB is the esbuild transpile service. Precompiling the worker would let this drop to 384Mi. |
| `synapse` | 20–40 mCPU steady, **200–400 mCPU during a bridge login**; 450–700 MiB RSS | 300m/1024Mi → 350m/1280Mi | CPU sized for the login burst, not steady state. Memory grounded down from Element's ESS smallest tier (2000 MiB, 1–500 users) — `homeserver.yaml` has no `caches:` block, so event cache is the 10K × 0.5 = 5K default and autotuning is off. CPython does not return arena memory promptly, so this is a high-water mark. |
| `mautrix-whatsapp` | **Measured 39 MiB cgroup / 61 MiB VmRSS at 1 live session**; est. ~160→280 MiB at 10→20 | 120m/768Mi → 180m/1024Mi | Measured figure is real but at one session. The per-account coefficient (~12 MiB) is an **estimate**. Headroom is insurance: an OOM mid-onboarding means merchants re-pair WhatsApp by hand. Ratio 1:6.25 is at the edge of legal — dropping CPU to 100m at 768Mi would be **illegal** (1:7.5). |
| `mautrix-meta` | **Measured 24 MiB cgroup / 47 MiB VmRSS at 1 session**; est. ~110→180 MiB | 100m/384Mi → 120m/512Mi | Lighter by config: `disable_xma_backfill`, `disable_typing` (removes 2 sockets/user), `thread_backfill.batch_count: 0`. |

**Correction carried from verification:** an earlier finding claimed backfill-disabled as a Meta-vs-WhatsApp differentiator. It is not — `mautrix-whatsapp/config.yaml:476` also reads `backfill: enabled: false`. Both bridges run backfill off. The consequence: the "+200–400 MiB transient during onboarding" figure is **unsupported** — `media_requests` is explicitly scoped to backfill, so with backfill off the media-fetch and sticker-transcode paths do not run at merchant login. `history_sync.max_initial_conversations: -1` still creates a portal room per conversation, which is real but far cheaper than the media path. I have sized the WhatsApp bridge for portal-creation burst only.

### A.4 — The blocker in this table

**There is no worker container image.** `services/backend/Dockerfile:55-60` — the `runner` target copies only `public/`, `.next/standalone`, `.next/static`. It omits `scripts/` and `tsx` (a devDependency). `npm run worker` is `tsx scripts/worker.ts` and **cannot execute in any built target**. `docker-compose.yml:44-48` works around this with a bare `node:22-alpine` + bind mount + `npm ci` at container start — which is not deployable. A new Dockerfile target is prerequisite to the `worker` row existing at all.

Related: nothing sets `NODE_ENV=production` for the worker, so `src/lib/db.ts:11` (`production ? 5 : 10`) gives it a **10**-connection pool, not 5. App-Postgres fan-out is 2×5 + 10 = **20** connections today, not 15.

---

## B. Three complete configurations

### The cluster fee, and how fragile the credit is

$0.10/cluster/hr = **$73.00/mo**. The GKE free tier is **$74.40/month in credits per billing account**, which covers exactly one zonal or Autopilot cluster. Three ways it evaporates:

1. **It is per billing account, not per cluster.** A staging cluster is the full $73/mo — no partial credit.
2. **It cannot be applied to compute**, only to the management fee, and unused credit does not roll over.
3. **Regional clusters are excluded entirely.** If you later want a regional control plane for availability, you pay $73/mo from that day.

I book it at $0.00 in all three configs and flag it: **budget $73/mo the moment a second cluster exists.**

### B.1 — LEAN

Single-replica backend, Postgres and Redis as in-cluster StatefulSets, Cloudflare for all static delivery, no Cloud SQL.

| Line | @10 | @20 |
|---|---:|---:|
| Autopilot pods (8: 5 app + app-PG + matrix-PG + Redis) | 84.30 | 99.45 |
| Cluster management fee (free-tier credit) | 0.00 | 0.00 |
| PD-balanced for PG + Synapse media PVCs (60/80 GiB @ $0.120) | 7.20 | 9.60 |
| Global ALB, 1 forwarding rule | 18.25 | 18.25 |
| ALB data processing (40/80 GiB @ $0.01) | 0.40 | 0.80 |
| Internet egress to Nigeria (40/80 GiB @ $0.15) | 6.00 | 12.00 |
| CDN + image storage — Cloudflare R2 + CDN (free tier) | 0.00 | 0.00 |
| Cloud DNS, 1 managed zone | 0.20 | 0.20 |
| Artifact Registry (5 GiB, first 0.5 free) | 0.45 | 0.45 |
| Secret Manager (15 versions, first 6 free) | 0.54 | 0.54 |
| Logging (under the 50 GiB/project free tier) | 0.00 | 0.00 |
| Monitoring (GCP system metrics are non-chargeable) | 0.00 | 0.00 |
| **TOTAL** | **116.50** | **141.29** |
| **Per merchant** | **$11.65** | **$7.06** |

Check @10: 84.30+7.20+18.25+0.40+6.00+0.20+0.45+0.54 = **116.50** ✅ · @20: 99.45+9.60+18.25+0.80+12.00+0.20+0.45+0.54 = **141.29** ✅

Lean pod detail (8 pods, @10): backend 1×200m/448Mi $10.52 · worker 120m/448Mi $7.18 · synapse 250m/896Mi/2Gi $14.77 · WA 100m/640Mi $7.21 · IG 80m/320Mi $4.92 · **app-PG 320m/2048Mi $22.78** · matrix-PG 200m/1024Mi $13.13 · redis 60m/256Mi $3.80 → **84.30**.

> The app-PG pod is 320m, not 300m, deliberately. 300m against 2048Mi is a **1:6.67 ratio — illegal on Autopilot** (max 1:6.5); Autopilot would silently raise the CPU. 2 GiB / 6.5 = 308 mCPU minimum, so 320m is the first clean value.

**LEAN's real cost is not on this table.** `ledger_entries` and `payouts` are settled money from day one. An in-cluster Postgres gives you no PITR and no tested restore. Take LEAN only for a pre-revenue pilot.

### B.2 — BALANCED ← **recommendation**

Cloud SQL for the money database, Matrix Postgres in-cluster (it is rebuildable from the bridges), managed Valkey, Cloud CDN on the ALB you already pay for.

| Line | @10 | @20 |
|---|---:|---:|
| Autopilot pods (6, §A) | 66.64 | 84.49 |
| Cluster management fee (free-tier credit) | 0.00 | 0.00 |
| Cloud SQL — app, 1 vCPU/3.75 GB, single-zone, 20/50 GB SSD + backups | 65.68 | 74.20 |
| Matrix Postgres — in-cluster pod (200m/1Gi → 250m/1.25Gi) | 13.13 | 16.38 |
| PD-balanced, Matrix PG + Synapse media (40/60 GiB) | 4.80 | 7.20 |
| Memorystore for **Valkey** `custom-pico` (1.25 GB), 1 node | 25.62 | 25.62 |
| Global ALB, 2 forwarding rules (:443 + :80 redirect) | 36.50 | 36.50 |
| ALB data processing (60/120 GiB) | 0.60 | 1.20 |
| Internet egress to Nigeria (50/100 GiB @ $0.15) | 7.50 | 15.00 |
| Intra-region inter-zone transfer (50/100 GiB @ $0.01) | 0.50 | 1.00 |
| CDN + product images — GCS + Cloud CDN (marginal, §C) | 1.21 | 1.60 |
| Electron update artifacts — Cloudflare R2 | 0.00 | 0.00 |
| Cloud DNS | 0.20 | 0.20 |
| Artifact Registry (10 GiB) | 0.95 | 0.95 |
| Secret Manager (25 versions) | 1.14 | 1.14 |
| Cloud Logging (60/80 GiB, 50 GiB free) | 5.00 | 15.00 |
| Cloud Monitoring | 10.00 | 10.00 |
| **TOTAL** | **239.47** | **290.48** |
| **Per merchant** | **$23.95** | **$14.52** |

Check @10: 66.64+65.68+13.13+4.80+25.62+36.50+0.60+7.50+0.50+1.21+0.20+0.95+1.14+5.00+10.00 = **239.47** ✅
Check @20: 84.49+74.20+16.38+7.20+25.62+36.50+1.20+15.00+1.00+1.60+0.20+0.95+1.14+15.00+10.00 = **290.48** ✅

Cloud SQL @10 arithmetic: (1 × $0.0496 × 730) + (3.75 × $0.0084 × 730) + (20 × $0.204) + (25 × $0.096) = 36.21 + 22.99 + 4.08 + 2.40 = **65.68**.

**Valkey over Redis:** Memorystore Valkey `custom-pico` (1.25 GB, **has an SLA**) is $0.0351/node-hr = $25.62/mo — 34% under Memorystore Redis Basic 1 GB ($38.69) and 61% under Redis Standard 1 GB ($65.70). Two nodes ($51.25) beat Redis Standard by 22% *with* replication. Note `custom-*` node types are excluded from committed-use discounts, so $25.62 is a floor you cannot negotiate down.

**Two ALB rules, not one.** A production HTTPS entrypoint provisions :443 plus a :80→:443 redirect. Budget both ($36.50) or explicitly ship HTTPS-only with no port-80 listener.

### B.3 — SAFE / HA

| Line | @10 | @20 |
|---|---:|---:|
| Autopilot pods (backend ×3, worker ×2, synapse, 2 bridges) | 166.00 | 180.98 |
| Cluster management fee (free-tier credit) | 0.00 | 0.00 |
| Cloud SQL — app, 2 vCPU/8 GB **HA**, 50/100 GB SSD + backups | 270.40 | 293.20 |
| Cloud SQL — Matrix, 1 vCPU/3.75 GB, 50 GB + backups | 74.20 | 74.20 |
| PD-balanced, Synapse media (60/80 GiB) | 7.20 | 9.60 |
| Memorystore Valkey `custom-pico` × 2 (replicated) | 51.25 | 51.25 |
| Global ALB, 2 forwarding rules | 36.50 | 36.50 |
| ALB data processing (100/200 GiB) | 1.00 | 2.00 |
| Cloud NAT (private nodes: 3 VMs + 1 IP) | 11.22 | 11.22 |
| Internet egress to Nigeria (100/200 GiB) | 15.00 | 30.00 |
| Intra-region inter-zone (200/300 GiB) | 2.00 | 3.00 |
| Cloud Armor Standard (1 policy + 5 rules + requests) | 25.00 | 25.75 |
| GCS + Cloud CDN product images | 1.21 | 1.60 |
| Cloudflare R2 — Electron updates | 0.00 | 0.00 |
| Cloud DNS | 0.20 | 0.20 |
| Artifact Registry (20 GiB) | 1.95 | 1.95 |
| Secret Manager (40 versions + 200k accesses) | 2.61 | 2.61 |
| Cloud Logging (100/150 GiB) | 25.00 | 50.00 |
| Cloud Monitoring + Managed Prometheus | 30.00 | 30.00 |
| **TOTAL** | **720.74** | **803.23** |
| **Per merchant** | **$72.07** | **$40.16** |

Check @10: 166.00+270.40+74.20+7.20+51.25+36.50+1.00+11.22+15.00+2.00+25.00+1.21+0.20+1.95+2.61+25.00+30.00 = **720.74** ✅
Check @20: 180.98+293.20+74.20+9.60+51.25+36.50+2.00+11.22+30.00+3.00+25.75+1.60+0.20+1.95+2.61+50.00+30.00 = **803.23** ✅

SAFE @20 also required a ratio fix: `mautrix-whatsapp` at 300m/2048Mi is 1:6.67 — illegal. Raised to **320m** (2 GiB / 6.5 = 308m minimum).

**SAFE buys less than it looks like.** Cloud SQL HA doubles vCPU, RAM and SSD but *not* backups. And Synapse still cannot run >1 replica — `homeserver.yaml` has no `worker_app`, no replication listeners, no redis block — and neither bridge can, because each holds a live per-account socket. **You are paying HA prices for a stack with three irreducible single points of failure.** Cloud Armor at $25/mo is also a judgement call: it buys nothing until you have an attacker.

### B.4 — Side by side

| | LEAN @10 | LEAN @20 | **BAL @10** | **BAL @20** | SAFE @10 | SAFE @20 |
|---|---:|---:|---:|---:|---:|---:|
| Total $/mo | 116.50 | 141.29 | **239.47** | **290.48** | 720.74 | 803.23 |
| Per merchant | 11.65 | 7.06 | **23.95** | **14.52** | 72.07 | 40.16 |
| PITR on money data | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |
| Backend survives a node drain | ❌ | ❌ | ✅ | ✅ | ✅ | ✅ |

Against the billing model's stated **$12–16/merchant/mo COGS budget**, Balanced @20 lands inside it at $14.52; Balanced @10 is 1.5–2× over, entirely on fixed cost.

---

## C. CDN and product-image delivery

### C.1 — What exists today (this is a migration, not greenfield)

- `image_url` is a plain nullable `text` column on `categories`, `brands`, `merchants`, `products` (`db/schema.sql:13,41,63,131`). No width/height/variant/checksum columns, no media table.
- **There is no upload path.** No multipart handler, no `@google-cloud/storage`, no S3 client, no presigned URLs anywhere in `services/backend/src`. Merchants paste a URL into a text field (`ProductFormScreen.tsx:549`, capped 2048 chars at `menu.ts:131`).
- Live dev DB: **65,318 product images and 5,575 merchant logos, 100% on third-party CDNs** — `images.snoonu.com` 59,853 (**91.6%**), plus cdngrubtech, deliverect, urbanpiper, limetray, Azure blob, S3.
- `boundedImage()` is duplicated verbatim in `api/v1/merchants/route.ts:22-25` and `.../[id]/route.ts:22-25`, and only truncates to 2048 + regex-checks `^https?://` — it will emit plaintext `http://` and any third-party host to clients.
- `next/image` **is** in use — 3 components (`auth-shell.tsx:2`, `echo-at-work.tsx:3`, `connector-logo.tsx:1`), reachable from `/`, `/login`, `/register`, `/invite`, `/reset-password` — but exclusively with local `/brand/*` assets, which is why `remotePatterns: []` has never broken anything. Two consequences: the Next.js image optimizer is already on a request-serving path in the backend pod, and pointing it at a CDN origin is a `remotePatterns` config edit, not a from-scratch adoption.
- Measured real catalog images: **~121 KiB mean, ~61 KiB median, already WebP** (12 sampled live URLs).
- Inbound WhatsApp/IG media is a **separate, non-CDN-able system**: bridges → Synapse `mxc://` → backend → base64 `data:` URI over authenticated JSON (`api/merchant/inbox/media/route.ts:60`). Forced by the Electron renderer's `connect-src 'none'`. The same CSP allows `img-src 'self' data: https:` (`vite.config.ts:22`) — which is exactly why **public CDN images work in the desktop app but inbox media cannot**.

### C.2 — Recommended design

**Product images: GCS + Cloud CDN on the ALB you are already paying for. Electron update artifacts: Cloudflare R2.** A deliberate split, justified below.

| Component | SKU | Config |
|---|---|---|
| Origin | Cloud Storage Standard, europe-west2 | `onsell-catalog-prod`, uniform bucket-level access, private; content-addressed keys `sha256/{hash}/{variant}.webp` |
| Delivery | Cloud CDN on the existing global external ALB | Bucket backend added to the same URL map as the API; `--enable-cdn` |
| Cache policy | `Cache-Control: public, max-age=31536000, immutable` | Safe because keys are content-addressed — a new image is a new key, never an invalidation |
| Renditions | `sharp`, already a backend dependency | 200px thumb / 600px card / 1600px full, all WebP, generated at upload |
| Update artifacts | Cloudflare R2 + Cloudflare CDN | `electron-updater` feed, blockmaps for differential download |

### C.3 — Cost

Marginal cost, i.e. **excluding the ALB forwarding rule**, which every configuration already pays for the API:

| Scale | Storage | Class A | Class B | Cache egress | Cache fill | Lookups | **Marginal $/mo** |
|---|---:|---:|---:|---:|---:|---:|---:|
| 10 merchants | 0.007 | 0.010 | 0.006 | 0.45 | 0.04 | 0.11 | **0.63** |
| 20 merchants | 0.014 | 0.010 | 0.006 | 0.90 | 0.04 | 0.23 | **1.20** |
| 100 merchants | 0.069 | 0.010 | 0.006 | 9.00 | 0.32 | 2.25 | **11.66** |
| 1,000 merchants | 0.690 | 0.010 | 0.006 | 90.00 | 3.20 | 22.50 | **116.41** |

Rates: GCS Standard $0.023/GiB-mo · Class A $0.005/1k · Class B $0.0004/1k · Cache egress **$0.09/GiB** · inter-region cache fill $0.04/GiB · lookups $0.0075/10k.

**Two corrections applied to the source research:**
1. **Cache egress bills on 100% of delivered bytes, hit or miss.** The 95% hit ratio governs cache *fill* and origin charges only. Applying it to egress under-bills the largest variable line; the figures above do not.
2. **Africa's egress tier is settled, not open.** Cloud CDN's pricing page states destination is "determined by where traffic leaves the Google network," and Cloud CDN has a **verified Lagos PoP** (plus Johannesburg, Mombasa). Nigerian traffic egresses in Africa → the catch-all "All other destinations" row at **$0.09/GiB**. Africa is the *third*-most-expensive Premium Tier band (behind China $0.23 and Australia/Korea/South America/Saudi $0.19), not the second.

**Electron auto-update:** does not exist today — no `electron-updater` dependency, no `publish` config, every packaging script ends `--publish never`, and only an unpacked `--dir` build has ever been produced (267 MB, 263 MB of it Chromium framework). Estimated compressed artifact **~110 MB** (an estimate — no DMG/ZIP/blockmap exists to measure).

| Scale (×2 seats, monthly release) | Cloud CDN | **R2** | Autopilot pod + egress |
|---|---:|---:|---:|
| 20 merchants (40 clients, 4.4 GB) | 0.40 | **0.00** | 0.51 |
| 1,000 merchants (2,000 clients, 220 GB) | 19.80 | **0.00** | 32.85 |

### C.4 — Why the split, plainly

**Cloud CDN wins product images** because the ALB is sunk. In an all-Autopilot shape there is no Cloud Run domain-mapping escape hatch — a GKE Gateway or Ingress *creates* a forwarding rule, so the $18.25 is unavoidable and shared with the API. Adding a bucket backend to the same URL map costs **$1.20/mo at 20 merchants**. One vendor, one IAM model, same-region origin, no cross-cloud egress.

**R2 wins Electron updates** for one specific reason: **zero egress on a per-seat full-file download**. This is the fastest-growing line in the whole study — it scales with seats × release cadence × 110 MB, independent of merchant activity. At 1,000 merchants it is $19.80/mo on Cloud CDN and $0.00 on R2, and it only diverges further. Nothing else in the artifact path benefits from being on GCP.

**Do not put product images on the Cloudflare Free plan.** Cloudflare's service-specific terms reserve the right to disable CDN access for serving "a disproportionate percentage of pictures" without a paid Images/R2/Stream product. A product-photo CDN is squarely in that language. R2 for artifacts is fine — that is a paid product being used as intended.

**Do not deploy imgproxy** ($12.77–$25.54/mo/replica on Autopilot). `sharp` is already a dependency and `src/lib/invoice-logo.ts:52-79` already fetches and downscales remote images. Use it at upload time.

**Cloudflare Images is a recurring cost, not one-off.** Cloudflare bills "unique transformations **within each calendar month**" and the count resets monthly. At 1,000 merchants that is **$60.50/month recurring** (~$726/yr), not a first-month charge — which makes it 4.7× the smallest imgproxy replica. At 20 merchants it is $0 every month (2,520 < 5,000 free).

### C.5 — Migration and build work

| # | Work | Notes |
|---|---|---|
| 1 | `POST /api/merchant/catalog/images` — multipart handler, ≤8 MB, magic-byte sniff | Nothing like this exists. Gate on `catalog.write`. |
| 2 | `sharp` rendition pipeline → 3 WebP variants, content-addressed keys | Reuse `invoice-logo.ts` fetch-and-resize; add `@google-cloud/storage` (first storage SDK in the repo). |
| 3 | Migration `NNN_media.sql`: `media` table + `image_media_id` FKs on 4 tables | Keep `image_url` during the cutover; dual-read. |
| 4 | Backfill script: fetch 65,318 third-party URLs → renditions → GCS | One-off, rate-limited. Snoonu will throttle. Budget a day. |
| 5 | Tighten `boundedImage()` to an origin allowlist, **de-duplicate it** | It currently accepts plaintext `http://` and arbitrary hosts. Live issue independent of the CDN. |
| 6 | `next.config.ts` `remotePatterns` → CDN origin | 3 components already use `next/image`; this is a config edit. |
| 7 | `ProductTable.tsx` renders thumbnails (currently deliberately does not) | The comment at :239 says a wall of remote thumbnails is the slowest thing on a shop connection. Own-CDN 15 KB thumbs change that calculus. |
| 8 | `electron-updater` + `publish` config + R2 bucket + code signing | Auto-update does not exist. Code signing is the long pole, not hosting. |

Volumes in §C.3 are **modelled, not measured** — there is no production traffic, and product images are not currently sent to customers over WhatsApp at all (`menu-pdf.ts` has no image handling). Treat the *ranking* as robust and the absolute dollars as indicative.

---

## D. Bridge-per-business

### D.1 — Current model: ONE shared process per provider, N sessions inside it

| Evidence | Location |
|---|---|
| Bridge addressed by **provider**, never merchant — two env vars total | `src/lib/matrix/client.ts:27-31` — `WA_BRIDGE_URL` / `IG_BRIDGE_URL` |
| **The proof line**: merchant is a *query param* on the shared URL | `client.ts:367-369` — `url.searchParams.set("user_id", userId)` |
| One bot mxid per provider, globally | `client.ts:40-41` — `@whatsappbot:` / `@metabot:` |
| Two ghost namespaces, no shard component | `client.ts:62-65` — `GHOST_PREFIXES` |
| Two bridge services, fixed container names and ports | `infra-matrix/docker-compose.yml:54-88` |
| **Three** appservice registrations (2 bridges + backend), not one per merchant | `synapse/homeserver.yaml:59-62` |
| Wildcard ghost namespace covering every merchant's contacts | `mautrix-whatsapp-registration.yaml:9-12` — `^@whatsapp_.*` |
| Bridges configured multi-tenant: any homeserver user may log in | `mautrix-whatsapp/config.yaml:282-285` — `"localhost": user` |
| One 5-connection pool per bridge for all tenants combined | `config.yaml:296-299` |
| No bridge-URL / instance / shard column anywhere in the schema | grep over `db/schema.sql` + `db/migrations/*.sql` returns nothing |
| Live runtime: exactly 1 `user_login` row in each bridge DB | `psql -d mautrix_whatsapp -tAc 'select count(*) from user_login'` → 1 |

`merchant_channels.bridge_login_id` (`009_matrix.sql:23`) is a bridgev2 UserLogin ID *inside* the shared process, not a bridge address.

### D.2 — Cost: shared vs per-business vs shard pool

| Model | @10 | @20 | $/merchant @10 | $/merchant @20 |
|---|---:|---:|---:|---:|
| **A. Shared (today)** — 2 pods, flat | **14.67** | **19.75** | 1.47 | 0.99 |
| B. Per-business, floor-sized (50m/320Mi + 50m/256Mi) | 70.48 | 140.97 | 7.05 | 7.05 |
| B. Per-business, realistic (100m/640Mi + 80m/320Mi) | 121.31 | 242.62 | 12.13 | 12.13 |
| B on Spot (floor-sized) — **not recommended** | 22.98 | 45.96 | 2.30 | 2.30 |
| **C. Pre-provisioned shard pool, K=4 pairs** | **48.52** | **48.52** | 4.85 | 2.43 |

Per-business unit arithmetic: WA 50m/320Mi/1Gi = (0.05 × 41.829) + (0.3125 × 4.629733) + (1 × 0.130597) = 2.091 + 1.447 + 0.131 = **$3.67**; IG 50m/256Mi/1Gi = 2.091 + 1.157 + 0.131 = **$3.38**; pair = **$7.05**.

**Crossover: 2.1 businesses floor-sized, 1.2 businesses at realistic sizing.** Per-business bridges are already more expensive than shared at your *second* merchant. Model A is flat; Model B is linear; there is no scale at which B wins.

If "per business" means genuine isolation with a database instance each, it is **(2N+1) Cloud SQL instances** — the +1 being Synapse, which still needs its own: **$1,286/mo at 10, $2,511/mo at 20**. At $61.24 per smallest sane Enterprise instance.

**Spot is arithmetic only, not a recommendation.** Preemption tears down the whatsmeow/Meta websocket, and `INSTAGRAM_BRIDGE.md` documents that a lost Instagram login has **no retry path** — a human re-does it in a browser. The cheapest row in the table is the most operationally dangerous.

### D.3 — Engineering work and blockers to go per-business

| Blocker | Detail |
|---|---|
| **Synapse restart per onboard** | `app_service_config_files` is read once, in `AppServiceConfig.read_config` (verified by reading Synapse 1.122.0 source inside the running container; no `reload` path exists). Under one-bridge-per-business, **onboarding merchant N restarts the homeserver for merchants 1..N−1.** This is the killer. |
| 16 `provisioningRequest` call sites | 12 in `src/lib/inbox.ts` (893, 945, 1034, 1062, 1164, 1170, 1509, 1528, 1574, 1588, 1605, 1933) + 4 in `src/lib/instagram-login.ts` (263, 317, 374, 413) — every one needs a merchant→bridge resolution threaded through |
| Per-instance ghost namespaces | Breaks `GHOST_PREFIXES` / `ghostFor` in `matrix/ingest.ts:51-60` and `typing.ts:48` |
| Per-merchant secrets | N × (`as_token`, `hs_token`, shared secret) in Secret Manager, N config templates |
| Outbound path | `inbox-outbound.ts:246-249` uses `bridgeAsToken` + `bridgeBotMxid` — both provider-global |
| Postgres connections | 20 today → 110 @10 → 210 @20 (Synapse 10 + 2 pods × 5 per merchant) |
| Provisioning lifecycle | Does not exist — no create/destroy/reassign for bridge instances |

### D.4 — The middle path: a pre-provisioned shard pool ← **recommend building this, later**

Register **K bridge instances at install time** (K=4 pairs: `wa-0..3`, `ig-0..3`), each with its own appservice registration in `homeserver.yaml` and disjoint ghost namespace (`^@whatsapp0_.*` … `^@whatsapp3_.*`). Add `merchant_channels.shard_id`. Assign merchants to shards at onboarding by least-loaded.

**This defeats the Synapse-restart problem entirely** — all K registrations exist from day one, so onboarding merchant N is a database write, not a homeserver restart.

| | Shared (A) | Shard pool K=4 (C) | Per-business (B) |
|---|---:|---:|---:|
| Cost @10 / @20 | 14.67 / 19.75 | **48.52 / 48.52** | 121.31 / 242.62 |
| Cost at 200 merchants | ~35 (1 pod pair, near limit) | **48.52 flat** | ~2,426 |
| Synapse restart on onboard | No | **No** | **Yes** |
| Blast radius of a bridge crash | All merchants | 1/K of merchants | 1 merchant |
| Code change | none | shard resolution + 1 column | full re-architecture |

Cost: 4 × ($7.21 + $4.92) = **$48.52/mo flat**, covering ~200 merchants at 50/shard. **+$33.85/mo over shared** buys blast-radius isolation and removes the restart cliff permanently.

### D.5 — Recommendation

**Keep shared bridges. Build the shard-pool abstraction (the `shard_id` column and resolution function) before you need it, but run K=1 until ~100 merchants.** That way the migration to K=4 is a config change and a backfill, not a re-architecture under pressure. Never build per-business bridges: the crossover is at your second merchant, and the Synapse restart makes onboarding an outage.

---

## E. All-in with AI

### E.1 — Plan catalog, read from `src/lib/billing.ts` today

Every tier runs `const HAIKU = "anthropic/claude-haiku-4.5"` (`billing.ts:134`). Model tier is deliberately **not** a plan lever any more.

| Plan | ₦/mo | $/mo @₦1,600 | AI conv/mo | Assistant q/mo | Remote rail |
|---|---:|---:|---:|---:|---:|
| Free | 0 | 0.00 | 0 | 20 | 2.50% |
| Starter | 25,000 | 15.62 | 200 | 300 | 2.00% |
| Growth | 60,000 | 37.50 | 600 | 1,000 | 1.50% |
| Scale (from) | 250,000 | 156.25 | 2,000 | 5,000 | 1.00% |

All capped per order at ₦2,000 (`REMOTE_FEE_CAP_MINOR`). Counter transfers are a flat ₦100 (`POS_TRANSFER_FLAT_MINOR`). Cash is never billed. Trial = 30 days, Growth entitlements, **150 conversations for the whole trial**.

### E.2 — AI unit cost (Haiku 4.5, $1.00 / $5.00 per MTok — current list price)

| Unit | Tokens (**estimate**, derived from code structure, never measured) | $ |
|---|---|---:|
| Sales conversation, **uncached** | ~72k in + 3k out | **0.0870** |
| Sales conversation, *if caching worked* | ~28k in + 3k out | 0.0430 |
| Assistant question | ~5k in + 0.5k out | 0.0075 |

> ### ⚠️ The caching lever probably does not work on Haiku 4.5
>
> **Haiku 4.5's minimum cacheable prefix is 4,096 tokens.** Prefixes shorter than that silently do not cache — no error, just `cache_creation_input_tokens: 0`. The stable prefix in `sales-agent.ts` is the system prompt (~1,200–1,500 tokens) plus 10 tool schemas (~2,500 tokens) ≈ **3,700–4,000 tokens — at or below the floor.**
>
> Worse: `system: systemPrompt(ctx)` interpolates live per-merchant catalog data, and `buildTools(ctx, state)` is also ctx-derived. Render order is `tools → system → messages`, so a per-merchant, catalog-varying prefix means the cache is per-merchant *and* invalidated whenever the catalog changes. At 10 merchants × ~150 conversations/month, back-to-back same-merchant conversations inside a 5-minute TTL will be rare.
>
> **Every "with caching" number in `gcp-deployment-architecture.md` §6d/§8 and `ai-metering-and-pricing.md` §4/§7 rests on an assumption that is very likely false on the model you actually ship.** I use the **uncached $0.0870** figure throughout below. If you want caching to work, the prefix must be padded above 4,096 tokens *and* made merchant-invariant — which means moving catalog data out of the system prompt and into a tool result.

### E.3 — Plan-level AI margin (uncached, before any infrastructure)

| Plan | $/mo | AI COGS @60% quota | GM @60% | AI COGS @100% | GM @100% |
|---|---:|---:|---:|---:|---:|
| Starter | 15.62 | 11.79 | **25%** | 19.65 | **−26%** |
| Growth | 37.50 | 35.82 | **4%** | 59.70 | **−59%** |
| Scale | 156.25 | 126.90 | **19%** | 211.50 | **−35%** |

**Every paid tier is loss-making at its own advertised allowance.** Growth clears 4% at 60% utilisation — before one cent of infrastructure, support, or payment processing. A merchant who uses what they bought loses you money on all three tiers.

### E.4 — All-in P&L (Balanced infra, uncached Haiku, 60% quota utilisation)

| Scenario | Merchants | Revenue | Infra | AI | **Profit** | GM |
|---|---:|---:|---:|---:|---:|---:|
| **All 10 on trial, month 1** | 10 | 0.00 | 239.47 | 130.50 | **−369.97** | — |
| Same, on LEAN infra | 10 | 0.00 | 116.50 | 130.50 | **−247.00** | — |
| Realistic mix (3 Free / 5 Starter / 2 Growth) | 10 | 153.12 | 239.47 | 130.86 | **−217.20** | −141.8% |
| Same, on LEAN infra | 10 | 153.12 | 116.50 | 130.86 | **−94.23** | −61.5% |
| Realistic mix (5F / 10St / 4G / 1Sc) | 20 | 462.50 | 290.48 | 388.53 | **−216.51** | −46.8% |
| Same, on LEAN infra | 20 | 462.50 | 141.29 | 388.53 | **−67.32** | −14.6% |
| Same @20, *if caching worked* | 20 | 462.50 | 290.48 | 219.57 | **−47.55** | −10.3% |
| All-Starter @20 | 20 | 312.50 | 290.48 | 235.80 | **−213.78** | −68.4% |

Trial COGS: 150 × $0.0870 = **$13.05/brand** uncached ($6.45 if caching worked). Ten concurrent trials = **$130.50** in month 1.

### E.5 — The part that matters

**Subscription revenue alone does not reach break-even at 10 or 20 merchants under any infrastructure configuration.** The best case on this table — LEAN infra, 20 merchants, realistic mix — is −$67/mo, and LEAN is the config with no PITR on the ledger.

The gap has to close from the **remote rail**, which is real revenue the tables above omit because it depends on GMV:

| | Blended remote rate | Remote GMV needed to break even | Per merchant |
|---|---:|---:|---:|
| @10, Balanced | 2.05% | **$10,595/mo** | ~$1,060 |
| @20, Balanced | 1.98% | **$10,963/mo** | ~$548 |

That is the number to validate before anything else in this document. **~$550–1,060/merchant/month of chat-and-invoice collected volume makes the business work at 20 merchants. It is a far more tractable target than any infrastructure optimisation** — the entire Balanced infra bill at 20 merchants is $290, which 1.98% of $14,670 of GMV covers on its own.

Note also that the trial waives the platform share entirely, so a month-1 cohort of ten trials generates **zero** revenue against $370 of cost. That is a defensible CAC decision — but budget it as acquisition spend, not infrastructure.

---

## F. Stale-doc corrections — `docs/gcp-deployment-architecture.md`

| # | § | What it says now | Correction |
|---|---|---|---|
| 1 | 3, 6a–6c, diagram | Cloud Run for backend and worker ($84 + $55 @10; $300 + $75 @100) | **No Cloud Run in this architecture.** Autopilot Deployments: $25.81 + $8.72 @10. Autopilot bills requests, not request count — the 19.9M req/mo line disappears. |
| 2 | 6 | "Add roughly **10%** for `europe-west2`" | Measured: **+20.0%** Cloud SQL and Persistent Disk, **+28.8%** Autopilot vCPU/memory, **+40.6%** Memorystore Redis Standard M1. The 10% assumption understates GKE compute by ~19 points. |
| 3 | 6 | Cloud SQL "$0.0413/vCPU-hr, $0.0070/GiB-hr, $0.17/GiB SSD" presented as the europe-west2 basis | Those are **us-central1** rates. europe-west2 is $0.0496 / $0.0084 / $0.204. |
| 4 | 6d, 7 | Growth and Scale run **Sonnet 5**; cost/conv $0.459 | `billing.ts:134` sets `const HAIKU` and every tier uses it. `salesAgentModel: HAIKU` on Starter, Growth **and** Scale. The Sonnet rows are dead. |
| 5 | 7 | Starter ₦15,000 / Growth ₦50,000 / Scale ₦150,000 | Current catalog: **₦25,000 / ₦60,000 / ₦250,000**. Growth quota is **600** conversations, not 500. |
| 6 | 8, lever 1 | "Enable prompt caching — saves ~$2,800/mo… the ~3,700-token stable prefix is comfortably above Sonnet 5's 1,024-token minimum" | Model is Haiku 4.5, whose **minimum cacheable prefix is 4,096 tokens**. A 3,700-token prefix silently will not cache. The prefix is also per-merchant and catalog-varying. **The highest-value lever in the document is, as written, a no-op.** |
| 7 | 4 | `useMessageAlerts` polls at **7s** | It polls at **5s** (`useMessageAlerts.ts:59`). Raises the always-on baseline from 20.6 to 24 req/min/instance (+16%). |
| 8 | 4, 5 | typing SSE "1 connection per window" | `useInboxTypingStream` is mounted by `InboxScreen.tsx:396`, not the shell. Concurrent SSE ≈ 40% of instances (8 @10, 16 @20), not 100%. |
| 9 | 4 | `InboxScreen` channels poll = 1 req/30s | Its `queryFn` is a `Promise.all` over `branchIds` (`InboxScreen.tsx:183-205`) — **one request per branch**. |
| 10 | 4 | Load model omits typing-broadcast POSTs | `typing.ts:202` `HEARTBEAT_MS = 4_000` + `:269-271` `setInterval` = **15 req/min at full composing duty cycle**, comparable to the entire channels-poll line. |
| 11 | 1 | Worker row: "Scales horizontally? Yes" | True *in principle* (DB leases + partial unique indexes serialize replicas), but **no worker container image exists** — `Dockerfile:55-60` omits `scripts/` and `tsx`. Nothing to scale yet. |
| 12 | 5 | "~2–5 GB RSS for WhatsApp" at 100 restaurants | Unsourced. **Measured: 39 MiB cgroup / 61 MiB VmRSS** with one live session (mautrix publishes no per-user figures — confirmed by fetching their setup page). Roughly an order of magnitude high at this scale. |
| 13 | 6a | "Skip the HTTPS Load Balancer at first — Cloud Run domain mapping gives you TLS for $0" | **Invalid in an all-Autopilot shape.** A GKE Gateway or Ingress creates a forwarding rule. The $18.25/mo (×2 with an HTTP redirect) is unavoidable. |
| 14 | 6b, 6c | GKE priced as Standard `e2-standard-8` node pools ($200 / $465) | Autopilot is pod-billed. Node size and count are irrelevant; the sizing tables in §A/§B replace these. |
| 15 | 9 | DB pool assumed 5/replica | Nothing sets `NODE_ENV=production` for the worker, so `db.ts:11` gives it **10**. Fan-out is 20 connections, not 15. |
| 16 | — | Missing cost lines throughout | Ephemeral storage (billed as a third Autopilot dimension, ≥1 GiB/container default), Cloud DNS ($0.20/zone/mo), intra-region inter-zone transfer ($0.01/GiB — the SAFE column's regional Cloud SQL spans zones by construction). |

**`docs/ai-metering-and-pricing.md`** carries the same drift: §4's plan table uses the retired ₦15,000/₦50,000/₦150,000 prices and Sonnet allocations; §7's infrastructure table ($337/mo at 10 restaurants) is the Cloud Run + single-VM shape, not Autopilot; and both rest on the same caching assumption as #6. Its §8 ("before changing any price, measure") is the one section that is still exactly right.

---

## G. Cost levers, ranked

Against **Balanced @20 = $290.48/mo**.

| $/mo saved | Lever | Trade-off |
|---:|---|---|
| **48.82** | Keep Matrix Postgres in-cluster instead of Cloud SQL | Already assumed in Balanced. Going the *other* way costs this. Matrix PG is rebuildable from the bridges; the app PG is not. |
| **21.82** | In-cluster Redis pod instead of Memorystore Valkey | Loses the SLA and managed failover. Redis holds sessions **and** an `allkeys-lru` cache — the pre-launch checklist already flags that mixing them is a fail-open on auth under memory pressure. Fix that first. |
| **18.25** | Drop the :80→:443 redirect rule; HTTPS-only listener | Users typing `http://` get a connection error rather than a redirect. Acceptable for a desktop app that hardcodes its URL. |
| **15.00** | Keep Cloud Logging under the 50 GiB/project free tier | Disable ALB request logging or sample it. At 40M req/mo, request logs are the only thing that gets you near 50 GiB. |
| **11.83** | Move region europe-west2 → **africa-south1** | Autopilot vCPU $0.049 vs $0.0573 (−14%), GCS Standard $0.020 vs $0.023, and **Cloud CDN cache fill halves** ($0.02/GiB intra-Africa vs $0.04 inter-region). Rejected in the doc for thin service catalogue and single-region-only — but it was never priced, and it is the region closest to the market. Worth a real evaluation. |
| **10.00** | Drop Managed Prometheus; GCP system metrics only | System metrics for GKE, Cloud SQL, LB and Memorystore are non-chargeable. 10k active series at a 15s scrape is ~1.73B samples/mo ≈ $104/mo — verify the scrape config before enabling it at all. |
| 13.82 | Spot for the bridges | **Do not do this.** Preemption drops the WhatsApp/Instagram session; a lost Instagram login has no retry path and requires a human. |
| **139.54** | **All of the above** → $150.94/mo | |

### The lever that actually matters

Everything in that table totals **$139.54/month**. The AI line at 20 merchants with a realistic mix is **$388.53/month**, and at 100% quota utilisation it is $700–900.

| Rank | Lever | Est. value |
|---|---|---:|
| **1** | **Make prompt caching actually work on Haiku 4.5** — pad the stable prefix above 4,096 tokens and move per-merchant catalog data out of the system prompt into a tool result | **~$170/mo @20**, and it is the difference between −$217 and −$48 monthly profit |
| **2** | **Re-price the catalog against measured token cost** — every paid tier is loss-making at its own allowance (§E.3) | Unbounded; this is the business |
| **3** | Move orders + message alerts onto the existing SSE channel | Near-zero on Autopilot (requests are free once the CPU request is set) — **but it shrinks the backend CPU request**, worth ~$10/mo, and it is the prerequisite for scaling past 100 merchants without re-sizing |
| **4** | Everything in the table above | $139.54/mo |

**Note how #3 changed meaning.** Under Cloud Run, killing the polling was the #2 lever worth ~60% of the compute bill. Under Autopilot it is worth almost nothing directly — you pay for the request, not the requests. That is the single most important consequence of the all-Autopilot decision, and it inverts the priority order in the existing doc.

---

## H. What to do first

1. **Measure the two numbers this whole study pivots on.** Run the `ai_usage_events` query in `ai-metering-and-pricing.md` §8 for 30 days, and add `cache_read_input_tokens` / `cache_creation_input_tokens` to `recordAiUsage`. Every AI figure here is derived from code structure, never observed. If `cache_read_input_tokens` is zero across repeated requests, correction #6 is confirmed and lever #1 is your top priority.

2. **Write the worker Dockerfile target.** No image exists. `npm run worker` cannot run in any built artifact. Nothing else in section A is deployable until this lands. Precompile rather than shipping `tsx` at runtime — it also drops ~60–80 MiB off the worker's memory request.

3. **Ship the Balanced configuration.** Cloud SQL for the app database from day one — `ledger_entries` and `payouts` are settled money and want PITR plus a *tested* restore. Matrix Postgres stays in-cluster. Valkey `custom-pico` over Memorystore Redis. Budget **$239/mo at 10, $290/mo at 20**.

4. **Fix the two prerequisites the checklist already names.** Split durable Redis (sessions, rate limits) from the `allkeys-lru` cache — one instance evicting sessions under memory pressure is a fail-open on auth. And fix the `redis.duplicate()` subscriber race in `inbox-typing-bus.ts:30`, which drops one typing reader per replica on every deploy.

5. **Stand up the CDN.** GCS bucket + Cloud CDN on the ALB's URL map (marginal $1.20/mo at 20), `sharp` renditions at upload, content-addressed immutable keys. Tighten `boundedImage()` to an origin allowlist while you are in there — it currently accepts plaintext `http://` and arbitrary third-party hosts, and it is duplicated in two files.

6. **Add `merchant_channels.shard_id` and a shard-resolution function — then run K=1.** Cost today: $0. It converts the eventual bridge-sharding migration from a re-architecture into a config change, and it permanently removes the Synapse-restart-per-onboard cliff before you can hit it.

7. **Validate the remote-rail GMV assumption.** You need roughly **$550/merchant/month** of chat-and-invoice collected volume at 20 merchants to break even. That single number decides whether the plan catalog needs re-pricing or just needs volume — and it is worth more than every line in section G combined.

**Do not** build per-business bridges (crossover is at merchant #2), deploy imgproxy (`sharp` is already there), put bridges on Spot (a lost Instagram session needs a human), or spend time optimising polling for cost reasons (Autopilot does not bill per request).