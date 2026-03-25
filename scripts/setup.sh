#!/usr/bin/env bash
# setup.sh - Set up a complete Fastly static hosting environment
#
# Creates everything needed to serve a static site from Fastly Object Storage
# via a VCL CDN service:
#
#   1. Object Storage access keys
#   2. Object Storage bucket (via S3-compatible API)
#   3. Fastly VCL service with domain, backend, and shield
#   4. Private Edge Dictionary for Object Storage credentials
#   5. VCL snippets for request signing and default document handling
#
# Prerequisites:
#   - Fastly CLI authenticated (run: fastly auth login)
#   - Fastly Object Storage enabled on your account
#   - curl >= 7.75 (for --aws-sigv4 support)
#   - jq
#
# Usage:
#   ./scripts/setup.sh <service-name> <domain> <bucket-name> <region>
#
# Example:
#   ./scripts/setup.sh staticly staticly.example.com my-site-bucket us-east

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <service-name> <domain> <bucket-name> <region>"
  echo ""
  echo "Arguments:"
  echo "  service-name  Name for the Fastly VCL service"
  echo "  domain        Domain name to attach to the service"
  echo "  bucket-name   Name for the Object Storage bucket"
  echo "  region        Object Storage region (e.g. us-east, eu-central, us-west)"
  echo ""
  echo "Available regions:"
  echo "  us-east, us-west, us-central-1, eu-central, eu-south-1,"
  echo "  uk-east-1, jp-central-1, au-east-1"
  exit 1
fi

SERVICE_NAME="$1"
DOMAIN="$2"
BUCKET_NAME="$3"
FOS_REGION="$4"
FOS_ENDPOINT="https://${FOS_REGION}.object.fastlystorage.app"

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

for cmd in fastly curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not installed." >&2
    exit 1
  fi
done

# Check curl version supports --aws-sigv4
CURL_VERSION=$(curl --version | head -1 | awk '{print $2}')
CURL_MAJOR=$(echo "$CURL_VERSION" | cut -d. -f1)
CURL_MINOR=$(echo "$CURL_VERSION" | cut -d. -f2)
if [[ "$CURL_MAJOR" -lt 7 ]] || [[ "$CURL_MAJOR" -eq 7 && "$CURL_MINOR" -lt 75 ]]; then
  echo "Error: curl >= 7.75 required for --aws-sigv4 (found $CURL_VERSION)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Check for existing service with the same name
# ---------------------------------------------------------------------------

EXISTING_ID=$(fastly service list --json 2>/dev/null | \
  jq -r ".[] | select(.Name == \"$SERVICE_NAME\") | .ServiceID" || true)

if [[ -n "$EXISTING_ID" && "$EXISTING_ID" != "null" ]]; then
  echo "Error: A service named '$SERVICE_NAME' already exists (ID: $EXISTING_ID)." >&2
  echo "Delete it first or choose a different name." >&2
  exit 1
fi

echo "============================================"
echo " Staticly - Fastly Static Hosting Setup"
echo "============================================"
echo ""
echo "Service name : $SERVICE_NAME"
echo "Domain       : $DOMAIN"
echo "Bucket       : $BUCKET_NAME"
echo "Region       : $FOS_REGION"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Create Object Storage access keys
# ---------------------------------------------------------------------------

echo "--- Step 1: Creating Object Storage access keys ---"

AK_JSON=$(fastly object-storage access-keys create \
  --description="${SERVICE_NAME}-deploy-key" \
  --permission=read-write-admin \
  --json \
  --non-interactive)

FOS_ACCESS_KEY=$(echo "$AK_JSON" | jq -r '.access_key')
FOS_SECRET_KEY=$(echo "$AK_JSON" | jq -r '.secret_key')

if [[ -z "$FOS_ACCESS_KEY" || "$FOS_ACCESS_KEY" == "null" ]]; then
  echo "Error: Failed to create access keys" >&2
  echo "$AK_JSON" >&2
  exit 1
fi

echo "Access key created: $FOS_ACCESS_KEY"
echo ""

# ---------------------------------------------------------------------------
# Step 2: Create Object Storage bucket via S3-compatible API
# ---------------------------------------------------------------------------

echo "--- Step 2: Creating Object Storage bucket ---"

BUCKET_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --aws-sigv4 "aws:amz:${FOS_REGION}:s3" \
  --user "${FOS_ACCESS_KEY}:${FOS_SECRET_KEY}" \
  -X PUT \
  -H "Content-Type: application/xml" \
  -d "<CreateBucketConfiguration><LocationConstraint>${FOS_REGION}</LocationConstraint></CreateBucketConfiguration>" \
  "${FOS_ENDPOINT}/${BUCKET_NAME}")

if [[ "$BUCKET_HTTP_CODE" -ge 200 && "$BUCKET_HTTP_CODE" -lt 300 ]]; then
  echo "Bucket '$BUCKET_NAME' created successfully"
elif [[ "$BUCKET_HTTP_CODE" -eq 409 ]]; then
  echo "Bucket '$BUCKET_NAME' already exists (continuing)"
else
  echo "Error: Failed to create bucket (HTTP $BUCKET_HTTP_CODE)" >&2
  exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Step 3: Create Fastly VCL service
# ---------------------------------------------------------------------------

echo "--- Step 3: Creating Fastly VCL service ---"

SERVICE_JSON=$(fastly service create \
  --name="$SERVICE_NAME" \
  --type=vcl \
  --non-interactive 2>&1)

# Extract service ID from the output (format: "Created service XXXX")
SERVICE_ID=$(echo "$SERVICE_JSON" | sed -n 's/.*Created service \([^ ]*\).*/\1/p' || true)

# If we couldn't parse it from text, try listing
if [[ -z "$SERVICE_ID" ]]; then
  SERVICE_ID=$(fastly service list --json | \
    jq -r ".[] | select(.Name == \"$SERVICE_NAME\") | .ServiceID")
fi

if [[ -z "$SERVICE_ID" || "$SERVICE_ID" == "null" ]]; then
  echo "Error: Failed to create service or extract service ID" >&2
  echo "$SERVICE_JSON" >&2
  exit 1
fi

echo "Service created: $SERVICE_ID"

# Write service ID to fastly.toml
cat > "$PROJECT_ROOT/fastly.toml" <<EOF
# Fastly service configuration for staticly
manifest_version = 3
service_id = "$SERVICE_ID"
EOF

echo ""

# ---------------------------------------------------------------------------
# Step 4: Add domain to the service
# ---------------------------------------------------------------------------

echo "--- Step 4: Adding domain ---"

fastly service domain create \
  --service-id="$SERVICE_ID" \
  --version=latest \
  --name="$DOMAIN" \
  --non-interactive

echo "Domain '$DOMAIN' added"
echo ""

# ---------------------------------------------------------------------------
# Step 5: Add Object Storage as a backend with shielding
# ---------------------------------------------------------------------------

echo "--- Step 5: Configuring Object Storage backend ---"

FOS_HOST="${FOS_REGION}.object.fastlystorage.app"

# Pick a shield POP close to the Object Storage region to reduce origin fetches
shield_pop() {
  case "$1" in
    us-east)      echo "iad-va-us" ;;
    us-west)      echo "sjc-ca-us" ;;
    us-central-1) echo "chi-il-us" ;;
    eu-central)   echo "amsterdam-nl" ;;
    eu-south-1)   echo "mxp-milan-it" ;;
    uk-east-1)    echo "london-uk" ;;
    jp-central-1) echo "tyo-tokyo-jp" ;;
    au-east-1)    echo "sydney-au" ;;
    *)            echo "" ;;
  esac
}

SHIELD=$(shield_pop "$FOS_REGION")
SHIELD_ARGS=()
if [[ -n "$SHIELD" ]]; then
  SHIELD_ARGS+=("--shield=$SHIELD")
  echo "Shield POP: $SHIELD"
fi

fastly service backend create \
  --service-id="$SERVICE_ID" \
  --version=latest \
  --name=object_storage \
  --address="$FOS_HOST" \
  --override-host="$FOS_HOST" \
  --use-ssl \
  --port=443 \
  --ssl-cert-hostname="$FOS_HOST" \
  --ssl-sni-hostname="$FOS_HOST" \
  "${SHIELD_ARGS[@]}" \
  --non-interactive

echo "Backend 'object_storage' configured"
echo ""

# ---------------------------------------------------------------------------
# Step 6: Create private Edge Dictionary for credentials
# ---------------------------------------------------------------------------

echo "--- Step 6: Creating private Edge Dictionary ---"

fastly service dictionary create \
  --service-id="$SERVICE_ID" \
  --version=latest \
  --name=object_storage_config \
  --write-only \
  --non-interactive

# Get the dictionary ID
DICT_ID=$(fastly service dictionary list \
  --service-id="$SERVICE_ID" \
  --version=latest \
  --json | jq -r '.[] | select(.Name == "object_storage_config") | .DictionaryID')

if [[ -z "$DICT_ID" || "$DICT_ID" == "null" ]]; then
  echo "Error: Failed to get dictionary ID" >&2
  exit 1
fi

echo "Dictionary created: $DICT_ID"

# Populate dictionary entries
for key_val in \
  "access_key:${FOS_ACCESS_KEY}" \
  "secret_key:${FOS_SECRET_KEY}" \
  "bucket:${BUCKET_NAME}" \
  "region:${FOS_REGION}"; do

  key="${key_val%%:*}"
  val="${key_val#*:}"

  fastly service dictionary-entry create \
    --dictionary-id="$DICT_ID" \
    --key="$key" \
    --value="$val" \
    --non-interactive
done

echo "Dictionary populated with credentials"
echo ""

# ---------------------------------------------------------------------------
# Step 7: Add VCL snippets
# ---------------------------------------------------------------------------

echo "--- Step 7: Adding VCL snippets ---"

for snippet in recv miss fetch error deliver; do
  vcl_file="$PROJECT_ROOT/vcl/${snippet}.vcl"
  if [[ -f "$vcl_file" ]]; then
    fastly service vcl snippet create \
      --service-id="$SERVICE_ID" \
      --version=latest \
      --name="staticly_${snippet}" \
      --type="$snippet" \
      --priority=10 \
      --content="$(cat "$vcl_file")" \
      --non-interactive
    echo "VCL snippet 'staticly_${snippet}' added (vcl_${snippet})"
  fi
done

echo ""

# ---------------------------------------------------------------------------
# Step 8: Activate the service
# ---------------------------------------------------------------------------

echo "--- Step 8: Activating service ---"

fastly service version activate \
  --service-id="$SERVICE_ID" \
  --version=latest \
  --non-interactive

echo "Service activated"
echo ""

# ---------------------------------------------------------------------------
# Save credentials to .env
# ---------------------------------------------------------------------------

ENV_FILE="$PROJECT_ROOT/.env"
cat > "$ENV_FILE" <<EOF
FOS_ACCESS_KEY=$FOS_ACCESS_KEY
FOS_SECRET_KEY=$FOS_SECRET_KEY
FOS_BUCKET=$BUCKET_NAME
FOS_REGION=$FOS_REGION
EOF
chmod 600 "$ENV_FILE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "============================================"
echo " Setup complete!"
echo "============================================"
echo ""
echo "Service ID    : $SERVICE_ID"
echo "Domain        : $DOMAIN"
echo "Bucket        : $BUCKET_NAME"
echo "Region        : $FOS_REGION"
echo "Access Key    : $FOS_ACCESS_KEY"
echo "Secret Key    : $FOS_SECRET_KEY"
echo ""
echo "Credentials saved to .env (chmod 600, in .gitignore)."
echo ""
echo "Next steps:"
echo "  1. Point your domain's DNS to Fastly"
echo "     (or use the Fastly-provided test URL)"
echo ""
echo "  2. Build and deploy your site:"
echo "     ./scripts/build.sh"
echo "     ./scripts/deploy.sh"
echo ""
echo "IMPORTANT: Do not commit .env to source control."
