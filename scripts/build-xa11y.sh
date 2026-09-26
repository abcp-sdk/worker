#!/usr/bin/env bash
# Build the `xa11y` computer-use CLI (github.com/xa11y/xa11y) into dist/.
#
# The sandbox images bake `xa11y` in so a job can read and drive native apps'
# accessibility trees. Upstream publishes NO prebuilt CLI binaries (only
# Python/JS wheels and crates), so it is built from source here and staged into
# dist/, exactly like the Go worker binaries.
#
#   scripts/build-xa11y.sh              # -> dist/xa11y-{linux,windows,macos wheel}
#   scripts/build-xa11y.sh linux
#   scripts/build-xa11y.sh windows
#   scripts/build-xa11y.sh macos-wheel
#
# Linux runtime deps (verified with `ldd`): glibc + libgcc +
# libxkbcommon.so.0. The desktop image installs libxkbcommon0; D-Bus/AT-SPI/X11
# are dlopen'd, so no link-time packages are needed.
#
# Windows is cross-built with an llvm-mingw toolchain (downloaded to a cache dir
# on first use) against the `x86_64-pc-windows-gnullvm` target with
# `+crt-static`, producing a self-contained .exe that needs only Windows system
# DLLs (no libunwind/libc++ redistributable).
#
# macOS is NOT cross-compiled (it needs the Apple SDK). Upstream publishes a
# prebuilt abi3 macOS wheel that bundles the CLI, so the `macos-wheel` target
# just downloads that wheel for the guest to pip-install.
#
# Env:
#   XA11Y_REPO    git URL          (default https://github.com/xa11y/xa11y)
#   XA11Y_TAG     git tag/ref      (default v0.15.0)
#   XA11Y_OUT     linux output     (default dist/xa11y-linux-amd64)
#   XA11Y_WIN_OUT windows output   (default dist/xa11y-windows-amd64.exe)
#   XA11Y_MAC_WHL macOS wheel      (default dist/xa11y-macos-amd64.whl)
#   LLVM_MINGW_DIR  toolchain dir  (default /tmp/opencode/llvm-mingw)
#   BUILD_PROXY   HTTP proxy       (default mihomo)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

XA11Y_REPO="${XA11Y_REPO:-https://github.com/xa11y/xa11y}"
XA11Y_TAG="${XA11Y_TAG:-v0.15.0}"
XA11Y_OUT="${XA11Y_OUT:-dist/xa11y-linux-amd64}"
XA11Y_WIN_OUT="${XA11Y_WIN_OUT:-dist/xa11y-windows-amd64.exe}"
XA11Y_MAC_WHL="${XA11Y_MAC_WHL:-dist/xa11y-macos-amd64.whl}"
XA11Y_PIP_VERSION="${XA11Y_PIP_VERSION:-0.15.0}"
BUILD_PROXY="${BUILD_PROXY:-http://mihomo.develop.svc.cluster.local:7890}"
LLVM_MINGW_DIR="${LLVM_MINGW_DIR:-/tmp/opencode/llvm-mingw}"
LLVM_MINGW_VERSION="${LLVM_MINGW_VERSION:-20260922}"

WANT="${*:-linux windows macos-wheel}"

CARGO="$(command -v cargo || true)"
[ -n "$CARGO" ] || { echo "cargo not found (need rust >= 1.88)" >&2; exit 1; }
# Resolve the REAL cargo (not a mise shim): the Windows build runs with a
# custom PATH that excludes the shims directory.
if command -v readlink >/dev/null && [ -L "$CARGO" ]; then
  CARGO="$(readlink -f "$CARGO")"
fi
RUSTBIN="$(dirname "$(command -v rustc)")"

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

build_linux() {
  echo "==> cargo build --release (linux) -p xa11y"
  HTTPS_PROXY="${BUILD_PROXY}" HTTP_PROXY="${BUILD_PROXY}" \
    "$CARGO" build --release -p xa11y --bin xa11y --manifest-path "${WORK}/xa11y/Cargo.toml"
  mkdir -p "$(dirname "${XA11Y_OUT}")"
  install -m 0755 "${WORK}/xa11y/target/release/xa11y" "${XA11Y_OUT}"
  echo "==> ${XA11Y_OUT} ($(du -h "${XA11Y_OUT}" | cut -f1))"
  ldd "${XA11Y_OUT}" | grep -vE 'linux-vdso|ld-linux|libc\.so|libm\.so|libgcc_s' || true
}

ensure_llvm_mingw() {
  local bin="${LLVM_MINGW_DIR}/bin"
  [ -x "${bin}/x86_64-w64-mingw32-clang" ] && return 0
  local asset="llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-x86_64.tar.xz"
  local url="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/${asset}"
  echo "==> fetching llvm-mingw ${LLVM_MINGW_VERSION}"
  mkdir -p "${LLVM_MINGW_DIR}"
  HTTPS_PROXY="${BUILD_PROXY}" HTTP_PROXY="${BUILD_PROXY}" \
    curl -fSL --retry 3 -o "${LLVM_MINGW_DIR}/${asset}" "${url}"
  tar -xf "${LLVM_MINGW_DIR}/${asset}" -C "${LLVM_MINGW_DIR}" --strip-components=1
  rm -f "${LLVM_MINGW_DIR}/${asset}"
}

build_windows() {
  ensure_llvm_mingw
  local bin="${LLVM_MINGW_DIR}/bin"
  echo "==> rustup target add x86_64-pc-windows-gnullvm"
  rustup target add x86_64-pc-windows-gnullvm >/dev/null 2>&1 || true
  echo "==> cargo build --release (windows, static) -p xa11y"
  # The custom PATH keeps the mingw tools but drops the mise shims (which break
  # under a rewritten PATH); cargo/rustc come from the absolute RUSTBIN.
  PATH="${bin}:${RUSTBIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  HTTPS_PROXY="${BUILD_PROXY}" HTTP_PROXY="${BUILD_PROXY}" \
  CARGO_TARGET_X86_64_PC_WINDOWS_GNULLVM_LINKER="${bin}/x86_64-w64-mingw32-clang" \
  RUSTFLAGS="-C target-feature=+crt-static" \
    "$CARGO" build --release -p xa11y --bin xa11y \
      --target x86_64-pc-windows-gnullvm \
      --manifest-path "${WORK}/xa11y/Cargo.toml"
  mkdir -p "$(dirname "${XA11Y_WIN_OUT}")"
  install -m 0644 "${WORK}/xa11y/target/x86_64-pc-windows-gnullvm/release/xa11y.exe" "${XA11Y_WIN_OUT}"
  echo "==> ${XA11Y_WIN_OUT} ($(du -h "${XA11Y_WIN_OUT}" | cut -f1))"
}

build_macos_wheel() {
  # macOS is NOT cross-compiled: xa11y-macos links Apple frameworks and
  # compiles Objective-C, so it needs the Apple SDK. Upstream instead publishes
  # a prebuilt abi3 macOS wheel that BUNDLES the CLI, so we just download that
  # (no Rust, no Xcode). The guest pip-installs it at bake/boot.
  echo "==> fetch xa11y ${XA11Y_PIP_VERSION} macOS wheel"
  mkdir -p "$(dirname "${XA11Y_MAC_WHL}")"
  local tmp; tmp="$(mktemp -d)"
  HTTPS_PROXY="${BUILD_PROXY}" HTTP_PROXY="${BUILD_PROXY}" \
    python3 -m pip download --no-deps --only-binary=:all: \
      --platform macosx_10_12_x86_64 --python-version 3.9 --implementation cp \
      --dest "${tmp}" "xa11y==${XA11Y_PIP_VERSION}" >/dev/null
  local whl; whl="$(find "${tmp}" -name '*.whl' | head -1)"
  [ -n "${whl}" ] || { echo "no macOS wheel found" >&2; rm -rf "${tmp}"; exit 1; }
  install -m 0644 "${whl}" "${XA11Y_MAC_WHL}"
  rm -rf "${tmp}"
  echo "==> ${XA11Y_MAC_WHL} ($(du -h "${XA11Y_MAC_WHL}" | cut -f1))"
}

for t in ${WANT}; do
  case "$t" in
    linux)       build_linux ;;
    windows)     build_windows ;;
    macos-wheel) build_macos_wheel ;;
    *) echo "unknown target '$t' (want linux|windows|macos-wheel)" >&2; exit 2 ;;
  esac
done
