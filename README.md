# Staticly

Host a static site entirely on Fastly using [Object Storage](https://docs.fastly.com/products/object-storage) as the origin and a VCL CDN service at the edge.

No external hosting provider or cloud storage needed. Files are uploaded to Fastly Object Storage via the S3-compatible API, and a VCL service with AWS SigV4 signing serves them through Fastly's CDN with edge caching and shielding.

The deployed site is the documentation — it explains in detail how everything works. You can also read it directly in [`site/index.html`](site/index.html).

## Prerequisites

- [Fastly account](https://www.fastly.com/signup) with Object Storage enabled
- [Fastly CLI](https://www.fastly.com/documentation/reference/cli/) (`fastly auth login`)
- `curl` >= 7.75, `jq`

## Quick Start

```bash
# Set up the Fastly service, bucket, dictionary, VCL, and shielding
./scripts/setup.sh <service-name> <domain> <bucket-name> <region>

# Build the site
./scripts/build.sh

# Deploy (credentials are loaded from .env, created by setup.sh)
./scripts/deploy.sh
```

## CI/CD

A [GitHub Actions workflow](.github/workflows/deploy.yml) automatically builds, deploys, and purges the cache when changes to `site/` are pushed to `main`.

Add these repository secrets in GitHub Settings > Secrets:

| Secret | Description |
|--------|-------------|
| `FOS_ACCESS_KEY` | Object Storage access key ID |
| `FOS_SECRET_KEY` | Object Storage secret key |
| `FOS_BUCKET` | Bucket name |
| `FOS_REGION` | Object Storage region (e.g. `us-east`) |
| `FASTLY_API_TOKEN` | Fastly API token (for cache purging) |

The first four are saved to `.env` by `setup.sh`. Create the API token at [manage.fastly.com](https://manage.fastly.com/account/personal/tokens).

## Teardown

```bash
./scripts/teardown.sh            # Delete service only
./scripts/teardown.sh --bucket   # Delete service and bucket
```

## Project Structure

```
├── .github/workflows/
│   └── deploy.yml        # Auto-deploy on push to main
├── site/                 # Static site source files
├── vcl/                  # VCL snippets (recv, miss, fetch, error, deliver)
├── scripts/
│   ├── setup.sh          # One-command Fastly service setup
│   ├── build.sh          # Copy site/ to dist/
│   ├── deploy.sh         # Upload dist/ to Object Storage
│   └── teardown.sh       # Remove service and clean up
├── fastly.toml           # Fastly CLI config (written by setup.sh)
└── .env                  # Credentials (written by setup.sh, gitignored)
```
