#!/usr/bin/env bash
#
# Builds the Trust Registry release binaries and uploads them to Cloudflare R2
# under both `latest/` and a versioned path
# (`<crate-version>-<git-short-sha>/`).
#
# Builds:
#   trust-registry      — trust-registry with secrets-config,storage-fjall  (uploaded as trust-registry/)
#   trust-registry-k8s  — trust-registry with secrets-vault,storage-fjall   (uploaded as trust-registry-k8s/)
#
# Required env vars (export them, or put them in <repo>/.env):
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   R2_ACCOUNT_ID
#   R2_BUCKET
#
# Usage:
#   .scripts/build-and-upload.sh            # build + upload
#   .scripts/build-and-upload.sh --build-only
#   .scripts/build-and-upload.sh --dry-run  # build + print aws cmds, don't upload

set -euo pipefail

BUILD_ONLY=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

for tool in cargo git jq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
if [[ $BUILD_ONLY -eq 0 ]]; then
  command -v aws >/dev/null || { echo "missing tool: aws (install aws-cli)" >&2; exit 1; }
fi

metadata="$(cargo metadata --no-deps --format-version 1)"

resolve_version() {
  local pkg="$1"
  local v
  v="$(printf '%s' "$metadata" | jq -r --arg p "$pkg" '.packages[] | select(.name==$p) | .version')"
  if [[ -z "$v" || "$v" == "null" ]]; then
    echo "Failed to resolve $pkg version" >&2
    exit 1
  fi
  printf '%s' "$v"
}

tr_version="$(resolve_version trust-registry)"
git_hash="$(git rev-parse --short HEAD)"

echo "==> versions: trust-registry=${tr_version} git=${git_hash}"

echo "==> building trust-registry (secrets-config)"
cargo build --release --no-default-features \
  --features "secrets-config,storage-fjall" \
  -p trust-registry
cp target/release/trust-registry target/release/trust-registry-standard

echo "==> building trust-registry (secrets-vault)"
cargo build --release --no-default-features \
  --features "secrets-vault,storage-fjall" \
  -p trust-registry
cp target/release/trust-registry target/release/trust-registry-k8s

for bin in target/release/trust-registry-standard target/release/trust-registry-k8s; do
  [[ -f "$bin" ]] || { echo "build succeeded but $bin missing" >&2; exit 1; }
done

if [[ $BUILD_ONLY -eq 1 ]]; then
  echo "==> --build-only set; skipping upload."
  exit 0
fi

for var in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ACCOUNT_ID R2_BUCKET; do
  if [[ -z "${!var:-}" ]]; then
    echo "missing env var: $var (set in shell or in <repo>/.env)" >&2
    exit 1
  fi
done

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="us-east-1"
ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

upload() {
  local src="$1" dest="$2"
  echo "==> uploading $src -> $dest"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "    [dry-run] aws s3 cp $src $dest --endpoint-url $ENDPOINT"
  else
    aws s3 cp "$src" "$dest" --endpoint-url "$ENDPOINT"
  fi
}

upload "target/release/trust-registry-standard" "s3://${R2_BUCKET}/trust-registry/latest/trust-registry"
upload "target/release/trust-registry-standard" "s3://${R2_BUCKET}/trust-registry/${tr_version}-${git_hash}/trust-registry"

upload "target/release/trust-registry-k8s" "s3://${R2_BUCKET}/trust-registry-k8s/latest/trust-registry"
upload "target/release/trust-registry-k8s" "s3://${R2_BUCKET}/trust-registry-k8s/${tr_version}-${git_hash}/trust-registry"

echo "==> done."
