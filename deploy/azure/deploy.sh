#!/usr/bin/env bash
# Deploys kt-mcp to Azure Container Apps. Idempotent: rerun it to ship a new
# build.
#
#   az login
#   ./deploy/azure/deploy.sh
#
# Nothing is built here. GitHub Actions (.github/workflows/image.yml) builds
# every push to main into ghcr.io, tagged sha-<commit>, and this script deploys
# the image of the checked-out commit. So push first, wait for the "Build
# image" workflow to go green, then deploy. The package must be public.
#
# KT_EMAIL, KT_PASSWORD and MCP_AUTH_PASSWORD come from the environment or from
# .env in the repository root. They reach Azure through main.bicepparam, never
# on a command line. Optional overrides:
#
#   AZURE_RESOURCE_GROUP  resource group to deploy into   (default kt-mcp)
#   AZURE_LOCATION        region                          (default westeurope)
#   AZURE_APP_NAME        Container App name              (default kt-mcp)
#   AZURE_PUBLIC_URL      custom domain, once it is bound (default: the app's own hostname)
#   AZURE_IMAGE_REPO      image repository                (default ghcr.io/honzajscz/kt-mcp)
#   AZURE_IMAGE           full image reference, overriding the repository and
#                         the commit tag (e.g. ghcr.io/you/kt-mcp:sha-1234567)
#
# AZURE_PUBLIC_URL is deliberately separate from PUBLIC_URL, which in .env
# belongs to the Cloudflare tunnel deployment.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

if [[ -f "$root/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$root/.env"
  set +a
fi

for name in KT_EMAIL KT_PASSWORD MCP_AUTH_PASSWORD; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing $name: export it or add it to $root/.env" >&2
    exit 1
  fi
done
export KT_EMAIL KT_PASSWORD MCP_AUTH_PASSWORD

resource_group="${AZURE_RESOURCE_GROUP:-kt-mcp}"
location="${AZURE_LOCATION:-westeurope}"
export AZURE_APP_NAME="${AZURE_APP_NAME:-kt-mcp}"
export AZURE_PUBLIC_URL="${AZURE_PUBLIC_URL:-}"

if [[ -z "${AZURE_IMAGE:-}" ]]; then
  # The workflow tags with the first 7 characters of the commit. Cut rather
  # than --short, which grows when a prefix is ambiguous.
  commit="$(git -C "$root" rev-parse HEAD)"
  AZURE_IMAGE="${AZURE_IMAGE_REPO:-ghcr.io/honzajscz/kt-mcp}:sha-${commit:0:7}"
  if [[ -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]]; then
    echo "Note: uncommitted changes are not deployed, only the image of ${commit:0:7}." >&2
  fi
fi
export AZURE_IMAGE

# Fail here with a useful message instead of in a revision that never starts.
# Only ghcr.io is checked; any other registry is trusted as given.
if [[ "$AZURE_IMAGE" == ghcr.io/*:* ]]; then
  path="${AZURE_IMAGE#ghcr.io/}"
  tag="${path##*:}"
  path="${path%:*}"
  echo "==> Checking $AZURE_IMAGE"
  token=$(curl -fsS "https://ghcr.io/token?scope=repository:$path:pull" 2>/dev/null \
    | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' || true)
  if [[ -z "$token" ]] || ! curl -fsS -o /dev/null --head \
      -H "Authorization: Bearer $token" \
      -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
      "https://ghcr.io/v2/$path/manifests/$tag" 2>/dev/null; then
    cat >&2 <<EOF
$AZURE_IMAGE cannot be pulled anonymously. Either:
  - the commit is not pushed, or its "Build image" workflow has not finished;
  - the package is still private (Package settings → Change visibility → Public).
EOF
    exit 1
  fi
fi

echo "==> Resource group $resource_group ($location)"
az group create --name "$resource_group" --location "$location" --output none

echo "==> Deploying $AZURE_IMAGE"
public_url=$(az deployment group create \
  --resource-group "$resource_group" \
  --name kt-mcp \
  --parameters "$here/main.bicepparam" \
  --query properties.outputs.publicUrl.value \
  --output tsv)

# The deployment returns once the revision is provisioned, which can be a
# little before the container answers.
echo "==> Waiting for $public_url/healthz"
for _ in $(seq 1 30); do
  if curl -fsS --max-time 10 "$public_url/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

"$root/scripts/verify-deployment.sh" "$public_url"
