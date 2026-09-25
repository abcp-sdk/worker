#!/usr/bin/env bash
# Build and push an agent-worker DESKTOP sandbox image.
#
#   ./agent-toolchain/desktop/build.sh openbox      # pure X11  (Xvfb+openbox+x11vnc)
#   ./agent-toolchain/desktop/build.sh labwc        # pure Wayland (labwc+wayvnc)
#
# SELF-CONTAINED / RUN-ONLY: the image bakes the screen stack AND the
# agent-worker binary, and its entrypoint starts both. The gateway runs only
# `sandbox-<lang>` images (agent-worker as the sole ENTRYPOINT), so this image
# is NOT used as a sandbox base; deploy it as a plain Deployment
# (k8s/agent-worker-desktop.yaml).
#
# Built FROM agent-toolchain/toolchain-base, so the base build tools come along.
#
# Prerequisites:
#   * dist/agent-worker-linux-amd64    (scripts/build-all.sh)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

FLAVOR="${1:-${FLAVOR:-openbox}}"
case "$FLAVOR" in
  openbox|labwc) ;;
  *) echo "unknown flavor '$FLAVOR' (want openbox|labwc)" >&2; exit 2 ;;
esac

REGISTRY="${REGISTRY:-git.agent.svc.cluster.local}"
NAMESPACE="${NAMESPACE:-sandbox}"
NAME="${NAME:-sandbox-desktop}"
TAG="${TAG:-$FLAVOR}"
DEST="${REGISTRY}/${NAMESPACE}/${NAME}:${TAG}"
BUILDKIT="${BUILDKIT_ADDR:-tcp://buildkitd.agent.svc.cluster.local:1234}"
PROXY="${PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
WORKER_BIN="${WORKER_BIN:-${ROOT}/dist/agent-worker-linux-amd64}"
# xa11y computer-use CLI (built by scripts/build-xa11y.sh). Only the X11/openbox
# flavor ships it (the a11y tree path is X11/AT-SPI-specific).
XA11Y_BIN="${XA11Y_BIN:-${ROOT}/dist/xa11y-linux-amd64}"
# The image is built FROM the generic toolchain base (build-essential etc.).
BASE_IMAGE="${BASE_IMAGE:-${REGISTRY}/agent-toolchain/toolchain-base:debian-trixie}"

FDIR="${DIR}/${FLAVOR}"
for f in "${FDIR}/Containerfile" "${FDIR}/entrypoint.sh" "${WORKER_BIN}"; do
  [ -e "$f" ] || { echo "missing $f" >&2; exit 1; }
done
# The openbox Containerfile COPYs ./xa11y; labwc does not.
COPY_XA11Y=""
if grep -q 'COPY --chmod=755 ./xa11y ' "${FDIR}/Containerfile"; then
  [ -e "${XA11Y_BIN}" ] || {
    echo "missing ${XA11Y_BIN}; run scripts/build-xa11y.sh first" >&2; exit 1; }
  COPY_XA11Y=1
fi

BUILDCTL="${BUILDCTL:-$(command -v buildctl || echo /opt/tools/mise/installs/aqua-moby-buildkit/0.32.2/bin/buildctl)}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cp "${FDIR}/Containerfile" "${WORK}/Dockerfile"
cp "${FDIR}/entrypoint.sh" "${WORK}/"
cp "${WORKER_BIN}" "${WORK}/agent-worker"
if [ -n "${COPY_XA11Y}" ]; then cp "${XA11Y_BIN}" "${WORK}/xa11y"; fi

echo "Building ${NAME}:${TAG} (flavor=${FLAVOR}, buildkitd=${BUILDKIT})"
"${BUILDCTL}" --addr "${BUILDKIT}" build \
  --frontend dockerfile.v0 \
  --local "context=${WORK}" \
  --local "dockerfile=${WORK}" \
  --opt "filename=Dockerfile" \
  --opt "build-arg:BASE_IMAGE=${BASE_IMAGE}" \
  --opt "build-arg:HTTP_PROXY=${PROXY}" \
  --opt "build-arg:HTTPS_PROXY=${PROXY}" \
  --opt "build-arg:NO_PROXY=localhost,127.0.0.1,.svc.cluster.local,.svc,.nip.io,10.199.64.20" \
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
