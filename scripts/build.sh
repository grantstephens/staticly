#!/usr/bin/env bash
# build.sh - Build the static site
#
# Copies the site source files into dist/ for deployment.
# This is where you would add minification, asset processing,
# or other build steps for a more complex site.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SITE_DIR="$PROJECT_ROOT/site"
DIST_DIR="$PROJECT_ROOT/dist"

echo "Building site..."

# Clean previous build
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Copy site files to dist
cp -r "$SITE_DIR"/* "$DIST_DIR"/

# Future build steps could go here, for example:
# - HTML/CSS/JS minification
# - Image optimisation
# - Generating a sitemap

echo "Build complete: $DIST_DIR"
find "$DIST_DIR" -type f | sort | while read -r file; do
  echo "  ${file#$DIST_DIR/}"
done
