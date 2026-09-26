# agent-worker macOS image

The agent-worker macOS (Sequoia) sandbox: a self-owned runtime (the generic
`qemux/qemu` Debian base + the vendored boot scripts in `vendor/`) wrapped
around a pre-baked guest disk that already contains the worker, its launcher and
the LaunchAgent/LaunchDaemon. No upstream sandbox image is referenced.

## Layout

- `Containerfile` — self-owned runtime: `FROM <registry>/qemu:750`, the OpenCore
  boot-image rebuild tools, the vendored boot scripts, the pre-baked disk +
  boot support, the boot-fetched worker + xa11y wheel, and the token bridge.
- `build.sh` — build + push (buildkitd → skopeo → the registry). Variants:
  `base` and `xcode`.
- `repack-disk.sh` — shrink the disk layer (defrag + long-window zstd).
- `vendor/` — boot scripts (`run/`), the OpenCore `config.plist`, and the
  OpenCore/VMHide archives.
- `guest/` — files baked *into the guest disk*:
  - `worker-launch.sh` — fetches `WORKER_TOKEN`, boot-fetches the worker from
    `host.lan:8090/worker`, installs the xa11y wheel from `/xa11y.whl`, and
    starts the worker in docker's Aqua session.
  - `bake-guest.sh` — one-time bake: passwordless sudo, launchd units,
    auto-login, xa11y install + Accessibility (TCC) grant.

## computer-use (xa11y)

The guest installs the **xa11y** CLI from a prebuilt abi3 wheel (nginx
`:8090 /xa11y.whl`; no Rust/Xcode needed) and drives native apps through
AXUIElement. Three things make this work and all are baked into the golden
disk:

1. **SIP off.** `config.plist` sets `csr-active-config=0x7f` AND lists
   `csr-active-config` under NVRAM/`Delete`, so the stale `0x00` in the
   pre-baked `macos.vars` no longer wins. Changing `config.plist` changes
   `openCoreSignature()`, so `boot.sh` rebuilds the OpenCore image on boot —
   which is why the Containerfile installs `xmlstarlet mtools file zip`.
2. **Command Line Tools.** The guest `/usr/bin/python3` is a CLT shim, so the
   wheel cannot be installed/run without them. `softwareupdate -i "Command
   Line Tools for Xcode-16.4"` installs them into the golden disk.
3. **TCC Accessibility.** The interpreter running the wheel needs
   `kTCCServiceAccessibility`. The grant is only possible with SIP off (the TCC
   db is SIP-protected); `bake-guest.sh` inserts it.

## Building

```sh
# stage (git-ignored): agent-toolchain/vm/macos/<variant>/data.qcow2
#                      agent-toolchain/vm/macos/<variant>/support/
scripts/build-all.sh                        # dist/agent-worker-darwin-amd64
scripts/build-xa11y.sh macos-wheel          # dist/xa11y-macos-amd64.whl
./agent-toolchain/vm/macos/build.sh base
./agent-toolchain/vm/macos/build.sh xcode

# optional: shrink the disk layer
qemu-img convert -f qcow2 -O qcow2 -o cluster_size=1M,lazy_refcounts=on \
  base/data.qcow2 base/defrag.qcow2
./agent-toolchain/vm/macos/repack-disk.sh base base/defrag.qcow2 <src> <dst>
```

The golden disk can be extracted straight from the published image (no
node-local copy needed): `skopeo copy docker://…/sandbox-macos:base dir:…`,
then `zstd -d | tar -x` the largest layer (`storage/15/data.qcow2`) and the
small `disk/support/*` layers (`storage/15/macos.*`). To rebake, boot that disk
as a hostPath `/storage` (a KVM pod on the image's node), run `bake-guest.sh`,
verify `xa11y apps`, shut down, defrag, then build a fresh image and push it
(see the `:a11y` tag).
