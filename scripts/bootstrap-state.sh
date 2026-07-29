#!/usr/bin/env bash
# One-time bootstrap. Run BEFORE the first `terraform init`.
#
# Creates the remote-state bucket, which cannot be a Terraform-managed resource
# in the same config that stores its state there.
#
# Prerequisite: the target project must have billing enabled. This script
# checks that invariant before enabling APIs or touching the state bucket.

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-chrome-oven-503818-h4}"
REGION="${REGION:-africa-south1}"
BUCKET="onsell-tfstate-${PROJECT_ID}"

if [[ "${PROJECT_ID}" != "chrome-oven-503818-h4" ]]; then
  echo "ERROR: this production backend is pinned to chrome-oven-503818-h4." >&2
  echo "       Create a separate backend before bootstrapping another project." >&2
  exit 1
fi

echo "==> Project: ${PROJECT_ID}   Region: ${REGION}"

# The active gcloud config points at a DIFFERENT project (oxyz-official), so
# every command here passes --project explicitly. Do not rely on config.
billing_enabled=$(gcloud billing projects describe "${PROJECT_ID}" \
  --format="value(billingEnabled)" 2>/dev/null || echo "false")

if [[ "${billing_enabled}" != "True" ]]; then
  echo "ERROR: billing is not enabled on ${PROJECT_ID} (billingEnabled=${billing_enabled})."
  echo "       Open or link a billing account, then re-run. Nothing below will work without it."
  exit 1
fi

echo "==> Enabling the APIs Terraform needs to bootstrap itself"
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  storage.googleapis.com \
  --project="${PROJECT_ID}"

if gcloud storage buckets describe "gs://${BUCKET}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  echo "==> State bucket gs://${BUCKET} already exists"
else
  echo "==> Creating state bucket gs://${BUCKET}"
  gcloud storage buckets create "gs://${BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access \
    --public-access-prevention
fi

# Versioning on state is not optional — it is the only undo for a bad apply.
gcloud storage buckets update "gs://${BUCKET}" --versioning --project="${PROJECT_ID}"

echo
echo "==> Done. Next:"
echo "    cd terraform/environments/production"
echo "    terraform init"
echo "    terraform plan -out=tfplan     # READ THIS BEFORE APPLYING"
echo "    terraform apply tfplan"
