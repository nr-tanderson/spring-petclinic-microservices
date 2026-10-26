#!/usr/bin/env bash
set -euo pipefail

: "${TFSTATE_STORAGE_ACCOUNT:?}"
: "${TFSTATE_CONTAINER:?}"
: "${TFSTATE_KEY:?}"
lock_blob="${TFSTATE_KEY}.operation-lock"
scratch=$(mktemp)
trap 'rm -f "$scratch"' EXIT

exists=$(az storage blob exists --account-name "$TFSTATE_STORAGE_ACCOUNT" --container-name "$TFSTATE_CONTAINER" --name "$lock_blob" --auth-mode login --query exists -o tsv)
if [[ "$exists" != true ]]; then
  printf 'Shared lab operation lock\n' > "$scratch"
  az storage blob upload --account-name "$TFSTATE_STORAGE_ACCOUNT" --container-name "$TFSTATE_CONTAINER" --name "$lock_blob" --file "$scratch" --auth-mode login --overwrite false -o none || true
fi
lease=$(az storage blob lease acquire --account-name "$TFSTATE_STORAGE_ACCOUNT" --container-name "$TFSTATE_CONTAINER" --blob-name "$lock_blob" --auth-mode login --lease-duration -1 --query leaseId -o tsv)
cleanup() {
  az storage blob lease release --account-name "$TFSTATE_STORAGE_ACCOUNT" --container-name "$TFSTATE_CONTAINER" --blob-name "$lock_blob" --auth-mode login --lease-id "$lease" -o none || true
  rm -f "$scratch"
}
trap cleanup EXIT
"$@"