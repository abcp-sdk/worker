#!/usr/bin/env bash
# Cross-compile the agent-worker binary used by the preset base image.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
CGO_ENABLED=0 GOOS=linux GOARCH="${GOARCH:-amd64}" \
  go build -C "${ROOT}" -trimpath -ldflags "-s -w" -o "${HERE}/agent-worker" ./cmd/agent-worker
ls -l "${HERE}/agent-worker"
