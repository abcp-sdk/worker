#!/usr/bin/env bash
# Shared per-language metadata for the on-demand toolchain index/publisher.
# Sourced (never executed) by build-index.sh and publish-artifacts.sh so the
# tool list lives in ONE place (no drift between generate + publish).
#
# Contract: abc-protocol/deploy/DEVELOP.md -> "Toolchain index".
#
#   PUBLISHED_LANGS            the installable set (phase 1: pure-unpack only)
#   toolchain_version <lang>   pinned version (the index key)
#   toolchain_requires <lang>  comma-separated toolchain deps ("" if none)
#   toolchain_kind <lang>      as-is | build
#       as-is  = relocatable prebuilt: upload the upstream cache artifact
#                verbatim; the installer unpacks it (strip/bin/rename).
#       build  = needs install.sh / a compile (PHASE 2): the publisher builds
#                once with the final prefix and ships the result.
#   toolchain_specs <lang>     one line per UPSTREAM cache artifact (as-is):
#                                <URLVAR>|<format>|<strip>|<bin>[|<rename>]
#       bin     relative to the version root ("{root}" allowed)
#       rename  "src->dst" (both relative to the version root, applied after
#               strip), e.g. dart: "dart-sdk->dart"
#
# strip/bin/rename mirror each Dockerfile.<lang>'s unpack (validate against it
# before trusting a new entry).

# ---- published (installable) set --------------------------------------------
# Phase 1 = "download -> verify -> unpack -> PATH", no install.sh, no compile:
#   go node python java25 dotnet php dart kotlin zig bun pixi
# (ruby is held back: its tarball needs LD_LIBRARY_PATH, i.e. env injection —
# see the phase-2 note in the MR/DEVELOP.)
# Phase 2 adds the build kinds (rust/elixir/clojure/r/lua) and the remaining
# pure-unpack langs (swift/julia/crystal/gleam/groovy/scala/sbt/cmake/ninja/
# godot/uv/cpanm/perl/deno/ocaml/haskell/conda/ruby).
PUBLISHED_LANGS="${PUBLISHED_LANGS:-go node python java25 dotnet php dart kotlin zig bun pixi}"

# ---- versions (the index key; kept explicit — upstream naming varies) --------
toolchain_version() {
  case "$1" in
    go) echo "1.27.1" ;; node) echo "26.9.0" ;; python) echo "3.14.7" ;;
    rust) echo "1.98.1" ;; java) echo "26.0.2.1" ;; java25) echo "25.0.4.1" ;;
    kotlin) echo "2.4.20" ;; scala) echo "1.17.1" ;; groovy) echo "4.0.33" ;;
    clojure) echo "1.12.6.1673" ;; dart) echo "3.13.4" ;; dotnet) echo "10.0.401" ;;
    elixir) echo "1.20.4" ;; gleam) echo "1.18.1" ;; php) echo "8.5.8" ;;
    ruby) echo "4.0.7" ;; swift) echo "6.4.0" ;; zig) echo "0.16.0" ;;
    bun) echo "1.4.2" ;; deno) echo "2.9.7" ;; julia) echo "1.13.0" ;;
    crystal) echo "1.21.0" ;; ocaml) echo "2.6.0" ;; haskell) echo "0.2.6.2" ;;
    lua) echo "5.5.1" ;; perl) echo "1.7049" ;; r) echo "4.6.1" ;;
    conda) echo "latest" ;; pixi) echo "latest" ;; godot) echo "4.7.2" ;;
    clang) echo "4.4.3" ;; *) echo "unknown" ;;
  esac
}

# ---- toolchain deps (index `requires`) --------------------------------------
toolchain_requires() {
  case "$1" in
    kotlin|groovy|clojure|scala) echo "java25" ;;
    *) echo "" ;;
  esac
}

# ---- publish kind -----------------------------------------------------------
toolchain_kind() {
  case "$1" in
    rust|elixir|lua|r|clojure) echo "build" ;;
    *) echo "as-is" ;;
  esac
}

# ---- upstream artifact specs (as-is) ----------------------------------------
# <URLVAR>|<format>|<strip>|<bin>[|<rename>]
toolchain_specs() {
  case "$1" in
    # ---- phase 1 (published now) ----
    go)      echo "GO_URL|tar.gz|1|bin" ;;
    node)    echo "NODE_URL|tar.xz|1|bin" ;;
    python)  echo "PYTHON_URL|tar.gz|1|bin" ;;               # install_only archive has a top `python/` dir
    java25)  echo "JDK25_URL|tar.gz|1|bin" ;;
    dotnet)  echo "DOTNET_URL|tar.gz|0|." ;;                 # dotnet at root (no strip)
    php)     echo "PHP_URL|tar.gz|1|bin;COMPOSER_URL|phar|0|bin/composer" ;;
    dart)    echo "DART_URL|zip|0|dart/bin|dart-sdk->dart" ;;  # keep top dir, rename dart-sdk -> dart
    kotlin)  echo "KOTLIN_URL|zip|1|bin" ;;
    zig)     echo "ZIG_URL|tar.xz|1|." ;;                    # zig at root
    bun)     echo "BUN_URL|zip|1|." ;;                       # bun at root
    pixi)    echo "PIXI_URL|raw|0|bin/pixi" ;;
    # ---- phase 2 (pure unpack, not yet published) ----
    java)    echo "JDK_URL|tar.gz|1|bin;GRADLE_URL|zip|1|bin" ;;
    scala)   echo "SCALA_CLI_URL|gz|0|bin/scala-cli;SBT_URL|tar.gz|1|bin" ;;
    groovy)  echo "GROOVY_URL|zip|1|bin" ;;
    gleam)   echo "GLEAM_URL|tar.gz|1|." ;;
    ruby)    echo "RUBY_URL|tar.gz|0|bin" ;;                 # NOTE: also needs LD_LIBRARY_PATH
    swift)   echo "SWIFT_URL|tar.gz|1|usr/bin" ;;
    deno)    echo "DENO_URL|raw|0|bin/deno" ;;
    julia)   echo "JULIA_URL|tar.gz|1|bin" ;;
    crystal) echo "CRYSTAL_URL|tar.gz|1|bin" ;;
    ocaml)   echo "OPAM_URL|raw|0|bin/opam" ;;
    haskell) echo "GHCUP_URL|raw|0|bin/ghcup" ;;
    perl)    echo "CPANM_URL|tar.gz|1|bin" ;;
    conda)   echo "CONDA_URL|raw|0|bin/miniconda.sh" ;;
    godot)   echo "GODOT_URL|zip|1|bin/godot" ;;
    clang)   echo "CMAKE_URL|tar.gz|1|bin;NINJA_URL|zip|1|bin" ;;
    # build kinds: publisher ships ONE relocatable tarball, strip 0 + bin "bin".
    rust|elixir|lua|r|clojure) echo "" ;;
    *) return 1 ;;
  esac
}

# bin dir for a BUILT relocatable (relative to the version root).
toolchain_build_bin() { echo "bin"; }

# ---- cache filename for an upstream URL var (mirrors fetch-artifacts.sh) -----
toolchain_cache_name() {
  case "$1" in
    HEXKEY_URL) echo "registry-public-key.pem" ;;
    *) local u="${!1%%\?*}"; u="${u##*/}"; echo "${u//%2B/+}" ;;
  esac
}
