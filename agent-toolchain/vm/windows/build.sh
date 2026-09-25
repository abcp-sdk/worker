#!/usr/bin/env bash
# Build and push the agent-worker Windows (win11) VM image.
#
#   ./agent-toolchain/vm/windows/build.sh [base|devtools]
#
# The image is a self-owned runtime (the generic qemux/qemu base + the vendored
# boot scripts in vendor/) wrapped around a pre-baked guest disk. Supply a
# *defragged* disk (uncompressed 1 MiB clusters) or the OCI layer will not
# compress — see repack-disk.sh.
#
# The worker binary is boot-fetched by the guest from nginx :8090 /worker; the
# windows binary COPYed here is the disk fallback.
#
# Expected layout (git-ignored, staged outside the repo):
#   <variant>/disk/data.qcow2      the guest disk
#   <variant>/disk-support/        windows.{base,boot,mac,rom,vars,ver}
#
# Prerequisites: dist/agent-worker-windows-amd64.exe (scripts/build-all.sh).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../../.." && pwd)"

VARIANT="${1:-base}"
case "$VARIANT" in
  base|devtools) ;;
  *) echo "usage: build.sh [base|devtools]" >&2; exit 2 ;;
esac

REGISTRY="${REGISTRY:-git.agent.svc.cluster.local}"
NAMESPACE="${NAMESPACE:-agent-toolchain}"
NAME="${NAME:-sandbox-windows}"
TAG="${TAG:-${VARIANT}}"
DEST="${REGISTRY}/${NAMESPACE}/${NAME}:${TAG}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.agent.svc.cluster.local:1234}"
PROXY="${PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
DISK="${DISK:-${DIR}/${VARIANT}/data.qcow2}"
SUPPORT="${SUPPORT:-${DIR}/${VARIANT}/disk-support}"
WORKER_BIN="${WORKER_BIN:-${ROOT}/dist/agent-worker-windows-amd64.exe}"
BUILDCTL="${BUILDCTL:-$(command -v buildctl || true)}"

for f in "${DIR}/Containerfile" "${DIR}/00-token.conf" "${DIR}/start.sh" "${DISK}" "${WORKER_BIN}"; do
  [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done
[ -d "${SUPPORT}" ] || { echo "missing support dir ${SUPPORT}" >&2; exit 1; }
[ -n "${BUILDCTL}" ] || { echo "buildctl not found (set BUILDCTL)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/disk"
cp "${DIR}/Containerfile" "${WORK}/Dockerfile"
cp "${DIR}/00-token.conf" "${DIR}/start.sh" "${WORK}/"
cp "${WORKER_BIN}" "${WORK}/agent-worker-windows.exe"
cp -r "${DIR}/vendor" "${WORK}/vendor"
ln "${DISK}" "${WORK}/disk/data.qcow2" 2>/dev/null || cp "${DISK}" "${WORK}/disk/data.qcow2"
cp -r "${SUPPORT}" "${WORK}/disk-support"

echo "Building ${NAME}:${TAG} -> ${DEST} (buildkitd=${BUILDKIT})"
echo "  disk: $(du -h "${WORK}/disk/data.qcow2" | cut -f1)"
"${BUILDCTL}" --addr "${BUILDKIT}" build \
  --frontend dockerfile.v0 \
  --local "context=${WORK}" \
  --local "dockerfile=${WORK}" \
  --opt "filename=Dockerfile" \
  --opt "build-arg:REGISTRY=${REGISTRY}/root" \
  --opt "build-arg:HTTP_PROXY=${PROXY}" \
  --opt "build-arg:HTTPS_PROXY=${PROXY}" \
  --output "type=oci,dest=${WORK}/image.oci,compression=zstd" \
  --progress plain

echo "Pushing to ${DEST}"
mkdir -p "${WORK}/oci" && tar -xf "${WORK}/image.oci" -C "${WORK}/oci"
skopeo copy --src-tls-verify=false --dest-tls-verify=false \
  --dest-creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" \
  "oci:${WORK}/oci" "docker://${DEST}"

echo "Verifying push:"
skopeo inspect --creds "${FORGEJO_USER:-root}:${FORGEJO_PASS:-devpassword}" \
  --tls-verify=false "docker://${DEST}" >/dev/null 2>&1 \
  && echo "OK ${DEST}" \
  || echo "inspect failed for ${DEST} (image may still be present)"
