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
| `base`     | clean Windows 11 + worker + computer-use (xa11y) |
| `devtools` | + Visual Studio Build Tools (MSVC) + Windows SDK + .NET SDK |

Both tags carry computer-use: the disk launcher boot-fetches `xa11y.exe` onto
PATH.

### Rebaking `devtools`

The devtools disk is a `base` disk plus a one-shot MSVC install, run inside the
guest (the guest has internet + admin). Recipe:

```cmd
curl.exe -sL -o %USERPROFILE%\vs_BuildTools.exe https://aka.ms/vs/17/release/vs_BuildTools.exe
%USERPROFILE%\vs_BuildTools.exe --quiet --wait --norestart --nocache ^
  --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended ^
  --add Microsoft.VisualStudio.Component.Windows11SDK.26100 ^
  --add Microsoft.VisualStudio.Component.Windows11SDK.22621 ^
  --add Microsoft.VisualStudio.Component.Windows81SDK
powershell -File dotnet-install.ps1 -Channel 10.0 -InstallDir "C:\Program Files\dotnet"
```

It produces VS Build Tools 2022 (17.14.x), MSVC 14.44.x, Windows SDK
10.0.22621 + 10.0.26100 (+ Kits 8.1) and .NET SDK 10.0.x. The launcher then
boot-fetches xa11y as on `base`, so `devtools` also has computer-use.

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
./agent-toolchain/vm/windows/repack-disk.sh base/defrag.qcow2 base base
```

The guest disk is rebuilt by booting the previous image's disk (hostPath-backed
so changes persist), running `guest/install-worker.cmd` inside it, then
committing and defragmenting it.

## computer-use (xa11y)

The image serves the **xa11y** Windows CLI at nginx `:8090 /xa11y.exe` and the
guest launcher (`guest/worker-launch.cmd`) boot-fetches it onto PATH, so a job
can read/drive native apps through UI Automation (`xa11y apps` / `tree` /
`find` / `action` / `screenshot`). No disk rebake is needed for a launcher or
CLI change — only the image.

The golden disk can be extracted straight from the published image (no
node-local copy needed): `skopeo copy docker://…/sandbox-windows:base dir:…`,
then `zstd -d | tar -x` the largest layer to get `storage/data.qcow2`, and the
small `disk-support` layers for `storage/windows.*`. To rebake, boot that disk
as a hostPath `/storage` (a KVM pod on the image's node), let the launcher run,
verify `xa11y apps`, `shutdown /s`, defrag (`qemu-img convert -o
cluster_size=1M`), then build a fresh image and push it as `base`.
