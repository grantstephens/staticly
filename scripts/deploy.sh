#!/usr/bin/env bash
# deploy.sh - Upload built site files to Fastly Object Storage
#
# Uses curl with --aws-sigv4 to upload each file in dist/ to the
# configured Object Storage bucket. No AWS CLI required.
#
# Credentials are loaded from .env if present, or from environment variables:
#   FOS_ACCESS_KEY  - Fastly Object Storage access key ID
#   FOS_SECRET_KEY  - Fastly Object Storage secret key
#   FOS_BUCKET      - Bucket name
#   FOS_REGION      - Object Storage region (e.g. us-east)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"

# Load .env if it exists and vars aren't already set
if [[ -f "$PROJECT_ROOT/.env" ]]; then
  # shellcheck source=/dev/null
  set -a
  source "$PROJECT_ROOT/.env"
  set +a
fi

# Check curl version supports --aws-sigv4
CURL_VERSION=$(curl --version | head -1 | awk '{print $2}')
CURL_MAJOR=$(echo "$CURL_VERSION" | cut -d. -f1)
CURL_MINOR=$(echo "$CURL_VERSION" | cut -d. -f2)
if [[ "$CURL_MAJOR" -lt 7 ]] || [[ "$CURL_MAJOR" -eq 7 && "$CURL_MINOR" -lt 75 ]]; then
  echo "Error: curl >= 7.75 required for --aws-sigv4 (found $CURL_VERSION)" >&2
  exit 1
fi

# Validate required environment variables
for var in FOS_ACCESS_KEY FOS_SECRET_KEY FOS_BUCKET FOS_REGION; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: $var is not set." >&2
    echo "Run scripts/setup.sh first, or set the variable manually." >&2
    exit 1
  fi
done

if [[ ! -d "$DIST_DIR" ]]; then
  echo "Error: dist/ directory not found. Run scripts/build.sh first." >&2
  exit 1
fi

FOS_ENDPOINT="https://${FOS_REGION}.object.fastlystorage.app"

# Map file extensions to MIME types
# Key is the path relative to dist/, with a leading / (e.g., /index.html).
# This matches the VCL which prepends /<bucket> to the request URL path.
mime_type() {
  local file="$1"
  case "${file##*.}" in
    html) echo "text/html; charset=utf-8" ;;
    css)  echo "text/css; charset=utf-8" ;;
    js)   echo "application/javascript; charset=utf-8" ;;
    json) echo "application/json; charset=utf-8" ;;
    xml)  echo "application/xml; charset=utf-8" ;;
    svg)  echo "image/svg+xml" ;;
    png)  echo "image/png" ;;
    jpg)  echo "image/jpeg" ;;
    jpeg) echo "image/jpeg" ;;
    gif)  echo "image/gif" ;;
    ico)  echo "image/x-icon" ;;
    webp) echo "image/webp" ;;
    woff) echo "font/woff" ;;
    woff2) echo "font/woff2" ;;
    ttf)  echo "font/ttf" ;;
    txt)  echo "text/plain; charset=utf-8" ;;
    *)    echo "application/octet-stream" ;;
  esac
}

echo "Deploying to ${FOS_ENDPOINT}/${FOS_BUCKET}..."
echo ""

errors=0
count=0

while IFS= read -r -d '' file; do
  key="${file#$DIST_DIR}"
  content_type=$(mime_type "$file")

  echo -n "  Uploading ${key} [${content_type}] ... "

  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --aws-sigv4 "aws:amz:${FOS_REGION}:s3" \
    --user "${FOS_ACCESS_KEY}:${FOS_SECRET_KEY}" \
    -X PUT \
    -H "Content-Type: ${content_type}" \
    --upload-file "$file" \
    "${FOS_ENDPOINT}/${FOS_BUCKET}${key}")

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    echo "OK"
  else
    echo "FAILED (HTTP $http_code)"
    errors=$((errors + 1))
  fi
  count=$((count + 1))
done < <(find "$DIST_DIR" -type f -print0 | sort -z)

echo ""
echo "Deployed $count files ($errors errors)"

if [[ "$errors" -gt 0 ]]; then
  exit 1
fi

# Remind about cache purge
echo ""
echo "To see changes immediately, purge the Fastly cache:"
echo "  fastly service purge --all"
