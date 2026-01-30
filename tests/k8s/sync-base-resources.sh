#!/bin/bash
# Sync base Kubernetes resources from parent directory to test overlay
# This is needed because kustomize security restrictions prevent referencing parent paths

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET_DIR="${SCRIPT_DIR}/base_resources"

echo "Syncing base resources from ${BASE_DIR} to ${TARGET_DIR}..."

mkdir -p "${TARGET_DIR}"

cp "${BASE_DIR}/configmap.yaml" "${TARGET_DIR}/"
cp "${BASE_DIR}/secret.yaml" "${TARGET_DIR}/"
cp "${BASE_DIR}/statefulset.yaml" "${TARGET_DIR}/"

echo "✓ Base resources synced successfully"
echo "  - configmap.yaml"
echo "  - secret.yaml"
echo "  - statefulset.yaml"
echo ""
echo "Run 'kubectl kustomize ${SCRIPT_DIR}' to build test manifests"
