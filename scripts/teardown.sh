#!/usr/bin/env bash
# teardown.sh - Remove a Staticly Fastly service and clean up
#
# Reads the service ID from fastly.toml and deletes the service.
# Optionally empties and deletes the Object Storage bucket.
#
# Usage:
#   ./scripts/teardown.sh              # Delete service only
#   ./scripts/teardown.sh --bucket     # Delete service and empty/delete bucket

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DELETE_BUCKET=false
if [[ "${1:-}" == "--bucket" ]]; then
  DELETE_BUCKET=true
fi

# ---------------------------------------------------------------------------
# Read service ID from fastly.toml
# ---------------------------------------------------------------------------

TOML_FILE="$PROJECT_ROOT/fastly.toml"
if [[ ! -f "$TOML_FILE" ]]; then
  echo "Error: fastly.toml not found. Nothing to tear down." >&2
  exit 1
fi

SERVICE_ID=$(sed -n 's/^service_id *= *"\(.*\)"/\1/p' "$TOML_FILE")
if [[ -z "$SERVICE_ID" ]]; then
  echo "Error: No service_id found in fastly.toml." >&2
  exit 1
fi

echo "============================================"
echo " Staticly - Teardown"
echo "============================================"
echo ""
echo "Service ID: $SERVICE_ID"

# ---------------------------------------------------------------------------
# Load .env for bucket credentials (if deleting bucket)
# ---------------------------------------------------------------------------

if [[ "$DELETE_BUCKET" == true ]]; then
  ENV_FILE="$PROJECT_ROOT/.env"
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
  fi

  for var in FOS_ACCESS_KEY FOS_SECRET_KEY FOS_BUCKET FOS_REGION; do
    if [[ -z "${!var:-}" ]]; then
      echo "Error: $var is not set. Cannot delete bucket without credentials." >&2
      echo "Set credentials in .env or as environment variables." >&2
      exit 1
    fi
  done
  echo "Bucket     : $FOS_BUCKET ($FOS_REGION)"
fi

echo ""
read -rp "Are you sure you want to delete this service? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

# ---------------------------------------------------------------------------
# Delete the Fastly service
# ---------------------------------------------------------------------------

echo ""
echo "--- Deleting Fastly service ---"

# Deactivate the active version first (required before delete)
ACTIVE_VERSION=$(fastly service-version list --service-id="$SERVICE_ID" --json 2>/dev/null | \
  jq -r '.[] | select(.Active == true) | .Number' || true)

if [[ -n "$ACTIVE_VERSION" && "$ACTIVE_VERSION" != "null" ]]; then
  fastly service-version deactivate \
    --service-id="$SERVICE_ID" \
    --version="$ACTIVE_VERSION" \
    --non-interactive 2>/dev/null || true
fi

fastly service delete \
  --service-id="$SERVICE_ID" \
  --force \
  --non-interactive

echo "Service deleted."

# ---------------------------------------------------------------------------
# Empty and delete the bucket (optional)
# ---------------------------------------------------------------------------

if [[ "$DELETE_BUCKET" == true ]]; then
  echo ""
  echo "--- Emptying Object Storage bucket ---"

  FOS_ENDPOINT="https://${FOS_REGION}.object.fastlystorage.app"

  # List all objects in the bucket
  objects=$(curl -s \
    --aws-sigv4 "aws:amz:${FOS_REGION}:s3" \
    --user "${FOS_ACCESS_KEY}:${FOS_SECRET_KEY}" \
    "${FOS_ENDPOINT}/${FOS_BUCKET}" 2>&1 | \
    grep -oP '<Key>\K[^<]+' || true)

  if [[ -n "$objects" ]]; then
    while IFS= read -r key; do
      echo "  Deleting $key"
      curl -s -o /dev/null \
        --aws-sigv4 "aws:amz:${FOS_REGION}:s3" \
        --user "${FOS_ACCESS_KEY}:${FOS_SECRET_KEY}" \
        -X DELETE \
        "${FOS_ENDPOINT}/${FOS_BUCKET}/${key}"
    done <<< "$objects"
  fi

  echo ""
  echo "--- Deleting bucket ---"

  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --aws-sigv4 "aws:amz:${FOS_REGION}:s3" \
    --user "${FOS_ACCESS_KEY}:${FOS_SECRET_KEY}" \
    -X DELETE \
    "${FOS_ENDPOINT}/${FOS_BUCKET}")

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    echo "Bucket '$FOS_BUCKET' deleted."
  elif [[ "$http_code" -eq 404 ]]; then
    echo "Bucket '$FOS_BUCKET' not found (already deleted)."
  else
    echo "Warning: Failed to delete bucket (HTTP $http_code)." >&2
    echo "You may need to delete it manually." >&2
  fi
fi

# ---------------------------------------------------------------------------
# Clean up local files
# ---------------------------------------------------------------------------

echo ""
echo "--- Cleaning up local files ---"

# Reset fastly.toml to template
cat > "$PROJECT_ROOT/fastly.toml" <<EOF
# Fastly service configuration for staticly
# service_id is written by scripts/setup.sh
manifest_version = 3
EOF
echo "  fastly.toml reset"

# Remove .env
if [[ -f "$PROJECT_ROOT/.env" ]]; then
  rm "$PROJECT_ROOT/.env"
  echo "  .env removed"
fi

# Remove dist
if [[ -d "$PROJECT_ROOT/dist" ]]; then
  rm -rf "$PROJECT_ROOT/dist"
  echo "  dist/ removed"
fi

echo ""
echo "============================================"
echo " Teardown complete"
echo "============================================"
echo ""
echo "Note: Object Storage access keys are not deleted automatically."
echo "List them with: fastly object-storage access-keys list"
echo "Delete with:    fastly object-storage access-keys delete --ak-id=<id>"
