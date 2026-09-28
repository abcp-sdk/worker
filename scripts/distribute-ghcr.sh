#!/usr/bin/env bash
# Mirror the in-cluster `sandbox/*` catalog to ghcr.io/silvermelon233.
#
#   GH_PASS=<github-pat-with-write:packages> ./scripts/distribute-ghcr.sh
#
# Every image is tagged `v0.1.0` (the project's single release tag). A repo with
# several variants keeps its canonical variant under the plain name and each
# other variant under a suffixed name:
#
#   sandbox-android            -> aosp     ; sandbox-android-gms       -> gms
#   sandbox-desktop            -> openbox  ; sandbox-desktop-labwc     -> labwc
#   sandbox-macos              -> base     ; sandbox-macos-xcode       -> xcode
#   sandbox-windows            -> base     ; sandbox-windows-devtools  -> devtools
#
# `sandbox-desktop:openbox` and `sandbox-windows:base` are the deployed 1920x1080
# builds; the VM repos' `base` tags are the golden disks (base + xa11y).
#
# Source: the in-cluster registry `git.agent.svc.cluster.local` (root:devpassword).
# The push goes through the build host's HTTP proxy (mihomo), so this must run
# where `ghcr.io` is reachable (the dev pod / build host).
set -euo pipefail

REGISTRY="${REGISTRY:-git.agent.svc.cluster.local}"
SRC_CREDS="${SRC_CREDS:-root:devpassword}"
GH_ORG="${GH_ORG:-ghcr.io/silvermelon233}"
GH_USER="${GH_USER:-SilverMelon233}"
: "${GH_PASS:?set GH_PASS to a GitHub PAT with write:packages}"

# src-repo:src-tag:dest-name triples
PAIRS="
sandbox/sandbox-android:aosp:sandbox-android
sandbox/sandbox-android:gms:sandbox-android-gms
sandbox/sandbox-base:debian-trixie:sandbox-base
sandbox/sandbox-bun:debian-trixie:sandbox-bun
sandbox/sandbox-clang:debian-trixie:sandbox-clang
sandbox/sandbox-clojure:debian-trixie:sandbox-clojure
sandbox/sandbox-comfyui:debian-trixie:sandbox-comfyui
sandbox/sandbox-conda:debian-trixie:sandbox-conda
sandbox/sandbox-crystal:debian-trixie:sandbox-crystal
sandbox/sandbox-cuda:debian-trixie:sandbox-cuda
sandbox/sandbox-dart:debian-trixie:sandbox-dart
sandbox/sandbox-deno:debian-trixie:sandbox-deno
sandbox/sandbox-desktop:openbox:sandbox-desktop
sandbox/sandbox-desktop:labwc:sandbox-desktop-labwc
sandbox/sandbox-dotnet:debian-trixie:sandbox-dotnet
sandbox/sandbox-elixir:debian-trixie:sandbox-elixir
sandbox/sandbox-gleam:debian-trixie:sandbox-gleam
sandbox/sandbox-go:debian-trixie:sandbox-go
sandbox/sandbox-godot:debian-trixie:sandbox-godot
sandbox/sandbox-groovy:debian-trixie:sandbox-groovy
sandbox/sandbox-haskell:debian-trixie:sandbox-haskell
sandbox/sandbox-java:debian-trixie:sandbox-java
sandbox/sandbox-java25:debian-trixie:sandbox-java25
sandbox/sandbox-julia:debian-trixie:sandbox-julia
sandbox/sandbox-kotlin:debian-trixie:sandbox-kotlin
sandbox/sandbox-llamacpp:debian-trixie:sandbox-llamacpp
sandbox/sandbox-lua:debian-trixie:sandbox-lua
sandbox/sandbox-macos:base:sandbox-macos
sandbox/sandbox-macos:xcode:sandbox-macos-xcode
sandbox/sandbox-node:debian-trixie:sandbox-node
sandbox/sandbox-ocaml:debian-trixie:sandbox-ocaml
sandbox/sandbox-perl:debian-trixie:sandbox-perl
sandbox/sandbox-php:debian-trixie:sandbox-php
sandbox/sandbox-pixi:debian-trixie:sandbox-pixi
sandbox/sandbox-python:debian-trixie:sandbox-python
sandbox/sandbox-r:debian-trixie:sandbox-r
sandbox/sandbox-ruby:debian-trixie:sandbox-ruby
sandbox/sandbox-rust:debian-trixie:sandbox-rust
sandbox/sandbox-scala:debian-trixie:sandbox-scala
sandbox/sandbox-swift:debian-trixie:sandbox-swift
sandbox/sandbox-torch:debian-trixie:sandbox-torch
sandbox/sandbox-vllm:debian-trixie:sandbox-vllm
sandbox/sandbox-vllm-omni:debian-trixie:sandbox-vllm-omni
sandbox/sandbox-windows:20260928:sandbox-windows
sandbox/sandbox-windows:devtools:sandbox-windows-devtools
sandbox/sandbox-zig:debian-trixie:sandbox-zig
"

ok=0; fail=0
for triple in $PAIRS; do
  repo="${triple%%:*}"; rest="${triple#*:}"; srctag="${rest%%:*}"; name="${rest##*:}"
  dst="$GH_ORG/$name:v0.1.0"
  echo "### $repo:$srctag -> $dst"
  if skopeo copy --all --retry-times 3 \
      --src-tls-verify=false --src-creds "$SRC_CREDS" \
      --dest-creds "$GH_USER:$GH_PASS" \
      "docker://$REGISTRY/$repo:$srctag" "docker://$dst"; then
    echo "OK $dst"; ok=$((ok+1))
  else
    echo "FAIL $dst"; fail=$((fail+1))
  fi
done
echo "=== done ok=$ok fail=$fail ==="
[ "$fail" -eq 0 ]
