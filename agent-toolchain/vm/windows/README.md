# agent-worker Windows image

The agent-worker Windows 11 sandbox: a self-owned runtime (the generic
`qemux/qemu` Debian base + the vendored boot scripts in `vendor/`) wrapped
around a pre-baked guest disk that already contains the worker, its launcher and
the scheduled task. No upstream sandbox image is referenced.

## Layout

- `Containerfile` — self-owned runtime: `FROM <registry>/qemu:750`, the vendored
  boot scripts, the pre-baked disk + boot support files, the boot-fetched worker
  binary, and the token bridge.
- `build.sh` — build + push (buildkitd → skopeo → the registry). Variants:
  `base` (plain) and `devtools` (MSVC + Windows SDK + .NET).
- `repack-disk.sh` — shrink the disk layer (defrag + long-window zstd).
- `vendor/` — the boot scripts + unattended assets copied in (not upstream).
- `guest/` — the files baked *into the guest disk* (not part of the image build):
  - `worker-launch.cmd` — fetches `WORKER_TOKEN` from `host.lan:8090/token`,
    boot-fetches the worker from `host.lan:8090/worker` (falling back to the
    disk copy), starts `agent-worker.exe` as the current user.
  - `ewelevate.cmd` — run a command as `NT AUTHORITY\SYSTEM` (escape hatch).
  - `agent-worker-task.xml` — the `AgentWorker` task definition (Docker user,
    HIGHEST, interactive, at logon). The hostname/user inside must match the
    guest; `install-worker.cmd` registers an equivalent task without XML.
  - `install-worker.cmd` — (re)install the worker in a running guest.

## Guest worker model

The worker runs as the **`Docker`** user in the interactive session, not as
SYSTEM. UAC is disabled in these images and `Docker` is an Administrator, so the
worker and every job it spawns already hold a full **High-IL** admin token.
`ewelevate.cmd` is there for the rare case that needs SYSTEM itself.

## Variants

| tag | contents |
|---|---|
| `v0.1.0-base`     | clean Windows 11 + worker |
| `v0.1.0-devtools` | + Visual Studio Build Tools (MSVC) + Windows SDK + .NET SDK |

## Building

```sh
# stage (git-ignored): agent-toolchain/vm/windows/<variant>/data.qcow2
#                      agent-toolchain/vm/windows/<variant>/disk-support/
scripts/build-all.sh                        # dist/agent-worker-windows-amd64.exe
./agent-toolchain/vm/windows/build.sh base
./agent-toolchain/vm/windows/build.sh devtools

# optional: shrink the disk layer
qemu-img convert -f qcow2 -O qcow2 -o cluster_size=1M,lazy_refcounts=on \
  base/data.qcow2 base/defrag.qcow2
./agent-toolchain/vm/windows/repack-disk.sh base/defrag.qcow2 v0.1.0-base v0.1.0-base
```

The guest disk is rebuilt by booting the previous image's disk (hostPath-backed
so changes persist), running `guest/install-worker.cmd` inside it, then
committing and defragmenting it.
