#!/usr/bin/env bash
# Generate the on-demand toolchain index (schema 1) consumed by the worker's
# toolchain installer (internal/toolchains; see abc-protocol/deploy/DEVELOP.md
# "Toolchain index").
#
#   ./build-index.sh                 # print index.json to stdout
#   ./build-index.sh -o index.json   # write to a file
#   ./build-index.sh --publish       # PUT to the artifact generic mount
#
# URLs come from toolchain/<DISTRO>/urls.env (+ urls.local.env overrides) — the
# SAME source the image builds use — and sha256 is computed from the local
# cache (fetch-artifacts.sh populates it). So there is one place to drift-proof.
# A missing cache artifact is a hard error (run ./fetch-artifacts.sh first).
#
# The per-language unpack metadata (format/strip/bin/requires/install) is a
# STARTING POINT derived from each language's Dockerfile install logic. Before
# publishing, validate each entry against its Dockerfile — several languages are
# NOT "unpack and go" (rust needs ./install.sh; lua/r compile from source;
# ghcup/opam/conda are single-file installers) and some archive roots differ.
# Treat `build-index.sh` as the drift-proof URL+sha256 source, not as a
# verified-per-language authority.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# config.sh reads NO_PROXY under `set -u`; default it so a bare environment works.
: "${NO_PROXY:=}"
# shellcheck source=config.sh
. "${HERE}/config.sh"

DIR="${HERE}/toolchain/${DISTRO}"
CACHE="${CACHE_ROOT}/${DISTRO}"
OUT=""
PUBLISH=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

set -a
# shellcheck source=/dev/null
. "${DIR}/urls.env"
[ -f "${HERE}/toolchain/urls.local.env" ] && . "${HERE}/toolchain/urls.local.env"
set +a

# Artifact metadata per language. Each spec is VAR|format|strip|bin; a language
# may have several (php = php + composer). `requires` / `install` are optional.
#
# bin: the PATH dir RELATIVE to the version root (or "{root}"-absolute).
meta() {
  case "$1" in
    go)        echo "GO_URL|tar.gz|1|bin" ;;
    node)      echo "NODE_URL|tar.xz|1|bin" ;;
    python)    echo "PYTHON_URL|tar.gz|0|bin" ;;   # install_only: already bin/
    rust)      echo "RUST_URL|tar.gz|0|" ;;         # install.sh populates the prefix
    java)      echo "JDK_URL|tar.gz|1|bin" ;;
    java25)    echo "JDK25_URL|tar.gz|1|bin" ;;
    kotlin)    echo "KOTLIN_URL|zip|1|bin" ;;
    scala)     echo "SCALA_CLI_URL|gz|0|bin/scala-cli;SBT_URL|tar.gz|1|bin" ;;
    groovy)    echo "GROOVY_URL|zip|1|bin" ;;
    clojure)   echo "CLOJURE_URL|tar.gz|1|bin" ;;
    dart)      echo "DART_URL|zip|1|bin" ;;
    dotnet)    echo "DOTNET_URL|tar.gz|1|" ;;       # sdk/ + dotnet at root
    elixir)    echo "OTP_URL|tar.gz|1|bin;ELIXIR_URL|zip|1|bin;HEX_URL|zip|1|;HEXKEY_URL|raw|0|" ;;
    gleam)     echo "GLEAM_URL|tar.gz|1|." ;;
    php)       echo "PHP_URL|tar.gz|1|.;COMPOSER_URL|phar|0|" ;;
    ruby)      echo "RUBY_URL|tar.gz|1|bin" ;;
    swift)     echo "SWIFT_URL|tar.gz|1|usr/bin" ;;
    zig)       echo "ZIG_URL|tar.xz|1|." ;;
    bun)       echo "BUN_URL|zip|1|." ;;
    deno)      echo "DENO_URL|zip|1|." ;;
    julia)     echo "JULIA_URL|tar.gz|1|bin" ;;
    crystal)   echo "CRYSTAL_URL|tar.gz|1|bin" ;;
    ocaml)     echo "OPAM_URL|raw|0|" ;;            # single-file installer
    haskell)   echo "GHCUP_URL|raw|0|" ;;           # single-file installer
    lua)       echo "LUA_URL|tar.gz|1|src;LUAROCKS_URL|tar.gz|1|bin" ;;
    perl)      echo "CPANM_URL|tar.gz|1|bin" ;;
    r)         echo "R_URL|tar.gz|1|bin" ;;
    conda)     echo "CONDA_URL|raw|0|" ;;           # .sh installer
    pixi)      echo "PIXI_URL|raw|0|" ;;            # single static binary
    godot)     echo "GODOT_URL|zip|1|." ;;
    clang)     echo "CMAKE_URL|tar.gz|1|bin;NINJA_URL|zip|1|." ;;
    *)         return 1 ;;
  esac
}
requires() {
  case "$1" in
    kotlin|groovy|clojure|scala) echo "java25" ;;
    *) echo "" ;;
  esac
}
install_argv() {
  case "$1" in
    rust) echo "./install.sh --prefix={root} --disable-ldconfig" ;;
    haskell) echo "{root}/ghcup" ;;
    *) echo "" ;;
  esac
}

# cache_name <var> mirrors fetch-artifacts.sh (the hex key is the one rename).
cache_name() {
  case "$1" in
    HEXKEY_URL) echo "registry-public-key.pem" ;;
    *) local u="${!1%%\?*}"; u="${u##*/}"; echo "${u//%2B/+}" ;;
  esac
}

# json_str: minimal JSON string escape (URLs/paths are plain ASCII here).
json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

emit() {
  local lang="$1" specs="$2" req="$3" inst="$4"
  local first_spec=1 art_out=""
  local IFS=';'
  for spec in $specs; do
    unset IFS
    local var="${spec%%|*}" rest="${spec#*|}"
    local format="${rest%%|*}" rest2="${rest#*|}"
    local strip="${rest2%%|*}" bin="${rest2#*|}"
    local url="${!var-}"
    if [ -z "$url" ]; then echo "missing url var $var for $lang" >&2; exit 1; fi
    local file; file="$(cache_name "$var")"
    local path="${CACHE}/${file}"
    if [ ! -s "$path" ]; then echo "missing cache artifact $file for $lang (run ./fetch-artifacts.sh $lang)" >&2; exit 1; fi
    local sha; sha="$(sha256sum "$path" | awk '{print $1}')"
    [ "$first_spec" -eq 1 ] || art_out+=","
    first_spec=0
    art_out+="{\"url\":$(json_str "$url"),\"sha256\":\"$sha\",\"format\":\"$format\",\"strip\":$strip,\"bin\":$(json_str "$bin")}"
    IFS=';'
  done
  unset IFS

  local req_json="[]"
  if [ -n "$req" ]; then req_json="[$(printf '%s' "$req" | awk -F, '{for(i=1;i<=NF;i++){printf "%s\"%s\"",(i>1?",":""),$i}}')]"; fi
  local inst_json=""
  if [ -n "$inst" ]; then
    inst_json=",\"install\":[$(printf '%s' "$inst" | awk '{for(i=1;i<=NF;i++){printf "%s\"%s\"",(i>1?",":""),$i}}')]"
  fi

  # Version key: the pinned version (kept explicit; the URL parse is ambiguous
  # across the many upstream naming schemes).
  local ver; ver="$(version_of "$lang")"

  printf '    %s: {"requires": %s, "versions": {"%s": {"artifacts": [%s]%s}}}\n' \
    "$(json_str "$lang")" "$req_json" "$ver" "$art_out" "$inst_json"
}

# version_of <lang>: the pinned version for the index key. Kept explicit (the
# URL parse is ambiguous across the many naming schemes).
version_of() {
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

generate() {
  echo "{"
  echo '  "schema": 1,'
  echo '  "toolchains": {'
  first=1
  for lang in ${WORKSPACE_LANGS}; do
    if ! specs="$(meta "$lang")"; then continue; fi
    [ "$first" -eq 1 ] || echo ","
    first=0
    emit "$lang" "$specs" "$(requires "$lang")" "$(install_argv "$lang")"
  done
  echo ""
  echo "  }"
  echo "}"
}

if [ "$PUBLISH" -eq 1 ]; then
  A="${ARTIFACT:-http://artifact.worker.svc.cluster.local}"
  : "${ARTIFACT_TOKEN:?set ARTIFACT_TOKEN to publish}"
  tmp="$(mktemp)"
  generate > "$tmp"
  curl -fsS -X PUT -H "Authorization: Bearer ${ARTIFACT_TOKEN}" \
    --data-binary "@${tmp}" "${A}/artifacts/generic/toolchains/index.json"
  rm -f "$tmp"
elif [ -n "$OUT" ]; then
  generate > "$OUT"
else
  generate
fi
