#!/usr/bin/env bash
set -euo pipefail

prohibited=0

while IFS= read -r -d '' file; do
  basename="${file##*/}"
  reason=""

  case "${file}" in
    .env.example|*/.env.example) ;;
    .env*|*/.env*) reason="environment file" ;;
    .terraform/*|*/.terraform/*) reason="Terraform working directory" ;;
    *media_store/*|*/logs/*|logs/*) reason="runtime data" ;;
  esac

  case "${basename}" in
    terraform.tfvars|*.auto.tfvars|tfplan*|*.tfplan|*.tfstate|*.tfstate.*)
      reason="Terraform value, state, or plan"
      ;;
    *.pem|*.key|*.p12|*.pfx)
      reason="private key"
      ;;
    *.log|*.log.*|*.db|*.sqlite|*.sqlite3)
      reason="runtime log or database"
      ;;
  esac

  if [[ -n "${reason}" ]]; then
    printf 'prohibited tracked path (%s): %s\n' "${reason}" "${file}" >&2
    ((prohibited += 1))
  fi
done < <(git ls-files -z)

if ((prohibited > 0)); then
  echo "Repository safety gate failed: ${prohibited} prohibited paths." >&2
  exit 1
fi

echo "Repository safety gate passed."
