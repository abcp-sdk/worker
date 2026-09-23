# agent-toolchain

The **`agent-toolchain`** image catalog: generic, deployment-neutral language
dev images pushed to the in-cluster registry under the `agent-toolchain`
namespace. The workspace gateway's `list-oci-images` default browses exactly
this namespace, and any of these images can be used as a **sandbox base** (the
gateway injects the worker into it at launch — derive-on-launch) or referenced
from `service-deploy`.

This tree was moved here from `workspace-gateway/images/` so the worker repo
owns the whole execution-image story (worker binary + the images sandboxes run
on). It is a curated subset of agent-worker's stage-1 toolchain build
(the upstream EasyLab worker images tree), with two deliberate differences:

- Registry/namespace default to the shared catalog
  (`git.agent.svc.cluster.local/agent-toolchain`) with NATIVE `<lang>:<distro>`
  tags.
- **No egress MITM CA and no worker binary are baked in** — the gateway injects
  agent-worker at sandbox launch. These are plain dev images.

## Layout

```
config.sh                 shared knobs (registry/namespace/distro/cache) + build_image()
build-toolchain.sh        build one language image (or `base`, or all)
build-all.sh              build base + every WORKSPACE_LANGS entry, one at a time
build-one.sh              detached single-image build with a log file
mirror-images.sh          mirror pinned middleware images (middleware.env)
middleware.Dockerfile     no-op FROM re-serve used by mirror-images.sh
middleware.env            pinned shared middleware image refs
toolchain/debian-trixie/  per-language Dockerfiles (+ base.Dockerfile, urls.env)
cache/debian-trixie/      pre-downloaded upstream artifacts (GITIGNORED, multi-GB)
```

## Build

```sh
# one image (base + one language), from the repo root or this dir:
DISTRO=debian-trixie ./build-toolchain.sh node
./build-toolchain.sh clang          # conan + clang + libc++ + llvm

# everything, one at a time, each to /tmp/wsbuild/<name>.log:
setsid bash build-all.sh > /tmp/wsbuild/all.log 2>&1 < /dev/null &
tail -f /tmp/wsbuild/all.log

# a single image, detached:
./build-one.sh toolchain node
```

The language set is `WORKSPACE_LANGS` in `config.sh`:
`node python go rust java kotlin scala dart dotnet elixir php ruby swift zig clang`.

## Middleware

`middleware.env` pins the shared middleware images (postgres / redis / mariadb /
nats) that every tenant sees via `list-oci-images`. Bump a version there, then:

```sh
./mirror-images.sh            # mirror every entry
./mirror-images.sh postgres   # just one
```

## Notes

- `cache/` holds the pre-downloaded upstream tarballs (`fetch-artifacts.sh` is
  the upstream helper; the artifacts are already present here). It is
  gitignored and rebuilt on demand — a build without a needed artifact fails
  loudly with the missing filename.
- `clang` builds from the raw distro base (it deliberately ships WITHOUT gcc);
  kotlin/scala extend `toolchain-java25`.
