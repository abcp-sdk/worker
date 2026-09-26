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

Every image is `<org>/<role>-<subject>:<tag>`. **All images a sandbox may run
live in the `sandbox` org** — the gateway's `CreateSandbox` refuses any other
org.

| org | role | subject | tag | example |
|---|---|---|---|---|
| `agent-toolchain` | `toolchain` | language | `debian-trixie` | `agent-toolchain/toolchain-node:debian-trixie` |
| `sandbox` | `sandbox` | language | `debian-trixie` | `sandbox/sandbox-node:debian-trixie` |
| `sandbox` | `sandbox` | OS | variant | `sandbox/sandbox-windows:devtools` |

OS sandboxes: `sandbox-{macos,windows,android,desktop}` with bare variant tags
(`base`/`xcode`/`devtools`/`aosp`/`gms`/`openbox`/`labwc`), matching the lang
trees' bare-distro tags. The repo's git tag (`v0.1.0`) carries the release.

### ML / GPU dev images

`cuda torch vllm vllm-omni llamacpp comfyui` are **dev images** (packages
installed so a job can build/run ML code; they are not meant to serve). They
chain off each other via `.base` files:

```
toolchain-cuda            (CUDA 13.4 toolkit + cuDNN 9 + CPython 3.13 + uv)
├── toolchain-torch       (torch 2.13.0 / vision 0.28.0 / audio 2.11.0 + HF stack)
│   ├── toolchain-vllm        (vllm 0.28.0)
│   │   └── toolchain-vllm-omni   (vllm-omni 0.28.0)
│   └── toolchain-comfyui     (ComfyUI v0.37.2 from git + its requirements)
└── toolchain-llamacpp    (llama.cpp b11182 CUDA build + llama-cpp-python 0.3.35)
```

Three things to know:

- **Python is 3.13, not the distro's 3.14.** vLLM-Omni pins `requires-python
  <3.14`; the whole ML stack lags the bleeding edge. `toolchain-python` (the
  separate language image) stays on 3.14.
- **CUDA runtime comes from pip, not the image's apt toolkit.** `pip install
  torch` pulls the `nvidia-*-cu13` wheels (~1.3 GiB); the apt toolkit only
  provides `nvcc`/headers for compiling. The **host driver** (`/dev/nvidia*`,
  `libcuda.so.1`) is never baked in — it is injected at runtime by the device
  plugin + `nvidia` RuntimeClass.
- **CUDA stubs are a lowest-priority ld path.** CUDA ships stub driver libs
  (SONAME `libcuda.so.1`) so a driverless box can still link/dlopen GPU code;
  `/etc/ld.so.conf.d/99-cuda-stubs.conf` registers them *after* the NVIDIA
  runtime's `00-nvcr-*.conf`, so a real driver wins when one is present. That is
  why `import torch` / `import llama_cpp` succeed with no GPU. `llama.cpp`
  prints "CUDA driver is a stub library" on such a box — expected.

To run an ML sandbox on a GPU box, call `CreateSandbox` with `gpu_count>=1`
(the gateway then sets the `nvidia` RuntimeClass + `nvidia.com/gpu` limit).


### OS sandbox call parameters (CreateSandbox)

The gateway exposes `kvm` and `cpu`/`memory`; the OS images need them:

| image | kvm | cpu/memory | notes |
|---|---|---|---|
| `sandbox/sandbox-desktop:{openbox,labwc}` | no | default fine | screen stack + noVNC; worker starts first |
| `sandbox/sandbox-android:{aosp,gms}` | **yes** | ≥4 / ≥8Gi | worker starts first; emulator boots in the background, so jobs must `adb wait-for-device` |
| `sandbox/sandbox-windows:{base,devtools}` | **yes** | 8 / 32Gi | guest RAM/CPU come from the image ENV; the pod must be sized above them |
| `sandbox/sandbox-macos:{base,xcode}` | **yes** | 4 / 16Gi | same |

The gateway's `CreateSandbox` waits only **60s** for `:48080`. The linux/desktop
images are ready in seconds; the VM/Android sandboxes boot a guest first, so the
call may return `DeadlineExceeded` while the sandbox is still coming up (it is
left in place and becomes ready on its own).

## Prerequisites on the host

- `buildctl` (moby/buildkit 0.32.x), `skopeo`, `curl`, go 1.26+, `qemu-img`.
- In-cluster services reachable: `buildkitd.agent.svc.cluster.local:1234`,
  `git.agent.svc.cluster.local` (registry, `root:devpassword`),
  `mihomo.develop.svc.cluster.local:7890` (HTTP proxy for upstream fetches).
- Registry + buildkitd MUST be in `NO_PROXY` (config.sh forces this).

## Build order

```sh
scripts/build-all.sh                       # 1. dist/ cross-compiled binaries (18 files)
scripts/build-xa11y.sh fetch               #    dist/xa11y-* (computer-use CLI)
./agent-toolchain/fetch-artifacts.sh       # 2. cache/<distro>/* toolchain tarballs
./agent-toolchain/build-toolchain.sh base   # 3. toolchain images (base first!)
./agent-toolchain/build-toolchain.sh node python ...   #    then languages
./sandbox-images/build.sh base node python ...         # 4. bake worker into them
./agent-toolchain/mirror-images.sh          # (optional) middleware images
```

`dist/` and `agent-toolchain/cache/` are **gitignored and NOT committed** — a
fresh checkout has neither. A build without the needed cache artifact fails
loudly with the missing filename (that is by design).

`dist/` binaries are published as **GitHub Releases** (never committed to git):
`v0.1.0` holds the six `agent-worker-*` binaries; `xa11y-v0.15.0` holds the
three `xa11y-*` CLI binaries. A fresh checkout repopulates the worker binaries
via `scripts/build-all.sh` and the xa11y ones via
`scripts/build-xa11y.sh fetch` (or builds them from source — see that script).

VM / Android / Desktop (separate, need `dist/` staged first). All four push to
the `sandbox` org (`NAMESPACE=sandbox` default):

```sh
./agent-toolchain/vm/macos/build.sh   base|xcode
./agent-toolchain/vm/windows/build.sh base|devtools
./agent-toolchain/android/build.sh    aosp|gms
./agent-toolchain/desktop/build.sh    openbox|labwc
```

The VM goldens (`<variant>/data.qcow2` + `disk-support/`) are git-ignored and
staged outside the repo; without them only a retag of the published image is
possible, not a rebuild.

## Registry / naming

- `REGISTRY=git.agent.svc.cluster.local`. Every sandbox-runnable image is under
  `NAMESPACE=sandbox`; generic toolchain bases are under `agent-toolchain`.
- Tags: lang sandbox images use `debian-trixie`; OS sandboxes use the bare
  variant. All names are `<role>-<subject>` — see the naming table above.
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

**Hex (elixir) is mirrored locally.** `repo.hex.pm/installs/{elixir}/hex-*.ez`
(and the registry public key) 301-redirects to a path that 404s, so the elixir
toolchain cannot fetch them upstream. Put the working files in
`toolchain/urls.local.env` (git-ignored) to point `fetch-artifacts.sh` at a
local store; do not "fix" the pinned URL in `urls.env` — it is correct, the
public path is just unstable.

## Known gotcha: buildkitd injects NO proxy into RUN steps

`buildkitd` runs without any HTTP proxy env of its own, so a `RUN` that talks
to the network (the apt layers in `Dockerfile.r`, `Dockerfile.godot`, the
distro/base setup) reaches `deb.debian.org` **directly at ~25 KB/s** instead of
~13.5 MB/s through `mihomo` — an apt layer that should take seconds crawls for
30+ minutes. Fixing it needs both halves:

1. `config.sh:build_image` passes `HTTP(S)_PROXY` + `NO_PROXY` as build-args;
   Dockerfile RUN steps inherit them as env automatically.
2. A Dockerfile whose RUN text never **references** the proxy still caches
   identically, so BuildKit may attach the new build to an **orphaned exec**
   left by an earlier killed client (BuildKit does not cancel an exec when its
   client dies). Declaring/referencing the arg (`echo "apt via ${HTTP_PROXY:-direct}"`)
   changes the step digest and forces a fresh, proxied exec.

Toolchain images that only `COPY cache/` (no network) are unaffected. The
predecessor tree passed the same build-args for its android/VM images
(`easyworker-new/images/*/build.sh`).

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
