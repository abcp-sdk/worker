# AGENTS.md — abcp-sdk/worker

Working notes for agents editing this repo. This repo is the **single source of
truth** for the `agent-worker` binary and every sandbox image a sandbox runs.
See `README.md` for the fork's RPC/behavior deltas; this file covers the build.

## Two image trees (do not confuse them)

| tree | script | produces | used by |
|---|---|---|---|
| `agent-toolchain/` | `build-toolchain.sh <lang>` | `<reg>/agent-toolchain/toolchain-<lang>:debian-trixie` | generic dev images; sandbox **bases**; `list-oci-images` default |
| `sandbox-images/` | `build.sh [langs]` | `<reg>/sandbox/sandbox-<lang>:debian-trixie` | the ONLY images a sandbox may run |

`agent-toolchain/` = plain distro + one toolchain, **no worker, no CA**.
`sandbox-images/` = a toolchain base + `cmd/agent-worker` baked in. The gateway
no longer injects the worker at launch, so **any worker change requires
rebuilding the `sandbox-*` images** (not just the toolchain ones).

Non-linux images live under `agent-toolchain/{vm,android,desktop}/` and are
run-only (not sandbox bases).

## Image naming (unified)

Every image is `<org>/<role>-<subject>:<tag>`:

| org | role | subject | tag | example |
|---|---|---|---|---|
| `agent-toolchain` | `toolchain` | language | `debian-trixie` | `agent-toolchain/toolchain-node:debian-trixie` |
| `sandbox` | `sandbox` | language | `debian-trixie` | `sandbox/sandbox-node:debian-trixie` |
| `agent-toolchain` | `sandbox` | OS | variant | `agent-toolchain/sandbox-windows:devtools` |

The OS sandboxes (`sandbox-macos`, `sandbox-windows`, `sandbox-android`,
`sandbox-desktop`) deliberately stay in **`agent-toolchain`**, NOT `sandbox`:
they ship their own entrypoint (screen stack / VM runtime + worker), so the
gateway's `CreateSandbox` must not treat them as gateway-launchable
`agent-worker`-ENTRYPOINT images. OS tags are the bare variant
(`base`/`xcode`/`devtools`/`aosp`/`gms`/`openbox`/`labwc`), matching the lang
trees' bare-distro tags. The repo's git tag (`v0.1.0`) carries the release.

## Prerequisites on the host

- `buildctl` (moby/buildkit 0.32.x), `skopeo`, `curl`, go 1.26+, `qemu-img`.
- In-cluster services reachable: `buildkitd.agent.svc.cluster.local:1234`,
  `git.agent.svc.cluster.local` (registry, `root:devpassword`),
  `mihomo.develop.svc.cluster.local:7890` (HTTP proxy for upstream fetches).
- Registry + buildkitd MUST be in `NO_PROXY` (config.sh forces this).

## Build order

```sh
scripts/build-all.sh                       # 1. dist/ cross-compiled binaries (18 files)
./agent-toolchain/fetch-artifacts.sh       # 2. cache/<distro>/* toolchain tarballs
./agent-toolchain/build-toolchain.sh base   # 3. toolchain images (base first!)
./agent-toolchain/build-toolchain.sh node python ...   #    then languages
./sandbox-images/build.sh base node python ...         # 4. bake worker into them
./agent-toolchain/mirror-images.sh          # (optional) middleware images
```

`dist/` and `agent-toolchain/cache/` are **gitignored and NOT committed** — a
fresh checkout has neither. A build without the needed cache artifact fails
loudly with the missing filename (that is by design).

VM / Android / Desktop (separate, need `dist/` staged first):

```sh
./agent-toolchain/vm/macos/build.sh   base|xcode
./agent-toolchain/vm/windows/build.sh base|devtools
./agent-toolchain/android/build.sh    aosp|gms
./agent-toolchain/desktop/build.sh    openbox|labwc
```

## Registry / naming

- `REGISTRY=git.agent.svc.cluster.local`, `NAMESPACE=agent-toolchain` (toolchain,
  VM/android/desktop), `SANDBOX_ORG=sandbox` (sandbox-images).
- Tags: toolchain/sandbox lang images use `debian-trixie`; OS sandboxes use the
  bare variant. All names are `<role>-<subject>` — see the naming table above.
- `scripts/retag.sh <src-repo> <src-tag> <dst-repo> <dst-tag>` re-tags within
  the registry via cross-repo blob mount (no bytes re-uploaded) — used to move
  the catalog to the unified names without rebuilding the multi-GB VM disks.
- ghcr mirror (optional, user-owned): `ghcr.io/silvermelon233`.

## Known gotcha: `fetch-artifacts.sh` provenance

`agent-toolchain/` was moved here from `workspace-gateway` (commit `91e6cc4`);
the move to drop the old easylab tree (`5a8b2f5`) **lost
`fetch-artifacts.sh`** while `.gitignore` and `config.sh`'s `CACHE_ROOT`
contract still require `cache/<distro>/`. It has been restored here; keep it in
sync with `CACHE_ROOT` and with the `COPY cache/<file>` lines in the
Dockerfiles. `HEXKEY_URL` is the one filename that does **not** match its URL
basename (`registry-public-key.pem`, not `hex-registry-public-key.pem`).

`conan-wheels-<ver>.tar.gz` is the one cache file with no single upstream
tarball; `fetch-artifacts.sh` assembles it from PyPI via `pip download` (conan
is public), pinned to CPython 3.14 / manylinux_2_28 so it works regardless of
the host's Python. Set `FETCH_CONAN=0` to skip it when not building `clang`.

## Effort (rough, single builder, cold cache)

- `scripts/build-all.sh`: ~1 min.
- `fetch-artifacts.sh` (all): several GB through the proxy, minutes-to-tens.
- `build-toolchain.sh` per language: 1–5 min (clang/rust/swift/dotnet slower).
- `sandbox-images/build.sh` per image: seconds (just COPYs the binary).
- VM images: dominated by disk upload; defrag first (`repack-disk.sh`) or the
  layer will not compress.

## Verification

- Worker: `go build ./... && go vet ./... && go test ./...`.
- Toolchain image: `skopeo inspect` and, for a language, `docker run … <lang> --version`.
- Sandbox image: deploy `k8s/agent-worker-*.yaml` and hit the worker's health
  endpoint on `:48080`; run `dist/awtest-<os>-amd64` for the full Connect surface.
- `scripts/multi-test.sh` runs awtest on linux/windows/macos in one report.

## Standing rules

- Never commit to `jj-lab`; report its bugs instead.
- Run lint/typecheck/tests before declaring done. Do not commit unless asked.
