# Sandbox images

Sandboxes run a **pre-built, worker-bundled** image. The gateway no longer
injects the worker at launch: `CreateSandbox` refuses any image whose registry
org is not `SANDBOX_ORG` (default `sandbox`).

`build.sh` bakes the agent-worker binary (cross-compiled from THIS repo,
`../cmd/agent-worker`) into an existing GENERIC toolchain image and pushes it to
`<registry>/<SANDBOX_ORG>/sandbox-<lang>:<distro-tag>`:

    ./build.sh                       # the default set (below)
    ./build.sh base node python      # a subset
    ./build.sh base                  # just the base

**The default set no longer includes the phase-1 languages** (`go node python
java25 dotnet php dart kotlin zig bun pixi`): they are published to the artifact
store and installed **on demand** by the worker (`WORKSPACE_TOOLCHAINS` →
`internal/toolchains`), so baking them is redundant. `java25` is the exception —
it stays because it is also the parent image of `kotlin/scala/clojure/groovy`
(`<lang>.base` → `toolchain-java25`).

The default set is therefore the not-yet-installable toolchains: `base rust java
java25 scala clojure groovy elixir gleam ruby swift clang deno julia crystal
ocaml haskell lua perl r conda godot cuda torch vllm vllm-omni llamacpp
comfyui` → `sandbox-<lang>:debian-trixie`. Phase-2 languages stay preinstalled
(declaring one has nothing to install from yet).

Re-run whenever the worker changes (a worker fix requires rebuilt images).
