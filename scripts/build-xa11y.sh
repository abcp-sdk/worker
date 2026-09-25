#!/usr/bin/env bash
# Build the `xa11y` computer-use CLI (github.com/xa11y/xa11y) into dist/.
#
# The desktop sandbox bakes `xa11y` in so a job can read and drive native apps'
# accessibility trees. Upstream publishes NO prebuilt CLI binaries (only
# Python/JS wheels and crates), so the binary is built from source here and
# staged into dist/, exactly like the Go worker binaries.
#
#   scripts/build-xa11y.sh            # -> dist/xa11y-linux-amd64
#
# Runtime deps of the produced binary (verified with `ldd`): glibc + libgcc +
# libxkbcommon.so.0. The desktop image installs libxkbcommon0; everything else
# (D-Bus/AT-SPI/X11) is dlopen'd at runtime, so no link-time packages are needed.
#
# Env:
#   XA11Y_REPO   git URL        (default https://github.com/xa11y/xa11y)
#   XA11Y_TAG    git tag/ref    (default v0.15.0)
#   XA11Y_OUT    output path    (default dist/xa11y-linux-amd64)
#   BUILD_PROXY  HTTP proxy for crate fetches (default mihomo)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

XA11Y_REPO="${XA11Y_REPO:-https://github.com/xa11y/xa11y}"
XA11Y_TAG="${XA11Y_TAG:-v0.15.0}"
XA11Y_OUT="${XA11Y_OUT:-dist/xa11y-linux-amd64}"
BUILD_PROXY="${BUILD_PROXY:-http://mihomo.develop.svc.cluster.local:7890}"

command -v cargo >/dev/null || { echo "cargo not found (need rust >= 1.88)" >&2; exit 1; }

# xa11y pins rust-version 1.88; fail early with a clear message.
rust_minor="$(rustc --version | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f2)"
if [ "${rust_minor:-0}" -lt 88 ]; then
  echo "rustc >= 1.88 required (xa11y rust-version); have $(rustc --version)" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "==> clone ${XA11Y_REPO} @ ${XA11Y_TAG}"
HTTPS_PROXY="${BUILD_PROXY}" HTTP_PROXY="${BUILD_PROXY}" \
  git clone --depth 1 --branch "${XA11Y_TAG}" "${XA11Y_REPO}" "${WORK}/xa11y"

echo "==> cargo build --release -p xa11y --bin xa11y"
HTTPS_PROXY="${BUILD_PROXY}" HTTP_PROXY="${BUILD_PROXY}" \
  cargo build --release -p xa11y --bin xa11y --manifest-path "${WORK}/xa11y/Cargo.toml"

mkdir -p "$(dirname "${XA11Y_OUT}")"
install -m 0755 "${WORK}/xa11y/target/release/xa11y" "${XA11Y_OUT}"
echo "==> ${XA11Y_OUT} ($(du -h "${XA11Y_OUT}" | cut -f1))"
ldd "${XA11Y_OUT}" | grep -vE 'linux-vdso|ld-linux|libc\.so|libm\.so|libgcc_s' || true
