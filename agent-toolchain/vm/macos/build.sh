#!/usr/bin/env bash
# Build and push the agent-worker macOS (Sequoia) VM image.
#
#   ./agent-toolchain/vm/macos/build.sh [base|xcode]
#
# The image is a self-owned runtime (the generic qemux/qemu base + the vendored
# boot scripts in vendor/) wrapped around a pre-baked guest disk. Supply a
# *defragged* disk (uncompressed 1 MiB clusters) or the OCI layer will not
# compress — see repack-disk.sh.
#
# The worker binary is boot-fetched by the guest from nginx :8090 /worker; the
# darwin binary COPYed here is the disk fallback.
#
# Expected layout (git-ignored, staged outside the repo):
#   <variant>/disk/data.qcow2        the guest disk
#   <variant>/disk/support/          boot.img, macos.rom/vars, identity
#
# Prerequisites: dist/agent-worker-darwin-amd64 (scripts/build-all.sh).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../../.." && pwd)"

VARIANT="${1:-base}"
case "$VARIANT" in
  base|xcode) ;;
  *) echo "usage: build.sh [base|xcode]" >&2; exit 2 ;;
esac

REGISTRY="${REGISTRY:-git.agent.svc.cluster.local}"
NAMESPACE="${NAMESPACE:-sandbox}"
NAME="${NAME:-sandbox-macos}"
TAG="${TAG:-${VARIANT}}"
DEST="${REGISTRY}/${NAMESPACE}/${NAME}:${TAG}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.agent.svc.cluster.local:1234}"
PROXY="${PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
DISK="${DISK:-${DIR}/${VARIANT}/data.qcow2}"
SUPPORT="${SUPPORT:-${DIR}/${VARIANT}/support}"
WORKER_BIN="${WORKER_BIN:-${ROOT}/dist/agent-worker-darwin-amd64}"
# xa11y computer-use CLI, shipped as a prebuilt abi3 macOS wheel (the guest
# pip-installs it). Built/fetched by scripts/build-xa11y.sh --macos-wheel.
XA11Y_WHL="${XA11Y_WHL:-${ROOT}/dist/xa11y-macos-amd64.whl}"
BUILDCTL="${BUILDCTL:-$(command -v buildctl || true)}"

for f in "${DIR}/Containerfile" "${DIR}/00-token.conf" "${DIR}/start.sh" "${DISK}" "${WORKER_BIN}" "${XA11Y_WHL}"; do
  [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done
[ -d "${SUPPORT}" ] || { echo "missing support dir ${SUPPORT}" >&2; exit 1; }
[ -n "${BUILDCTL}" ] || { echo "buildctl not found (set BUILDCTL)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/disk/support"
cp "${DIR}/Containerfile" "${WORK}/Dockerfile"
cp "${DIR}/00-token.conf" "${DIR}/start.sh" "${WORK}/"
cp "${WORKER_BIN}" "${WORK}/agent-worker-darwin"
cp "${XA11Y_WHL}" "${WORK}/xa11y.whl"
cp -r "${DIR}/vendor" "${WORK}/vendor"
ln "${DISK}" "${WORK}/disk/data.qcow2" 2>/dev/null || cp "${DISK}" "${WORK}/disk/data.qcow2"
# Boot support only; base.dmg (install media) is not shipped (see Containerfile).
for f in boot.img boot.sig macos.id macos.mac macos.mlb macos.rom macos.sn macos.vars; do
  [ -e "${SUPPORT}/$f" ] && cp -f "${SUPPORT}/$f" "${WORK}/disk/support/"
done

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
