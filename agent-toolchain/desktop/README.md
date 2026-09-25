# agent-worker desktop sandbox

Self-contained, run-only graphical sandboxes: a screen stack (virtual display +
VNC + noVNC) plus the agent-worker binary, all in one image, viewable in a
browser. Built `FROM agent-toolchain/toolchain-base`, so the base build tools
come along (no extra toolchain is installed).

Two flavors:

| flavor | stack | use when |
|---|---|---|
| `openbox` | **pure X11**: `Xvfb :99 → openbox → x11vnc :5900 → websockify :6080` | jobs must **drive X11 apps** (xdotool/xclip/xsel are X11-only) |
| `labwc`   | **pure Wayland**: `labwc (headless) → wayvnc :5900 → websockify :6080` | native Wayland clients |

> X11-only automation (`xdotool`, `xclip`, `xsel`) **cannot** target Wayland
> clients, and labwc does not provide an X server. If you need to drive an X11
> app, use the `openbox` flavor.

## Gateway sandbox

Unlike `sandbox-<lang>` images (whose sole `ENTRYPOINT` is `agent-worker`), this
image ships its **own** entrypoint that starts the screen stack *and*
agent-worker. The gateway does not override the entrypoint, so it is a normal
`CreateSandbox` target like any `sandbox/` image (no `kvm` needed). The worker
comes up first (readiness in seconds); the screen stack starts in the
background.

You can also run it as a plain Deployment — exactly like
`k8s/agent-worker-android.yaml`:

```sh
kubectl apply -f k8s/agent-worker-desktop.yaml   # edit image tag for the flavor
```

Endpoints (in-pod): `:48080` worker API, `:6080` noVNC (open, ClusterIP only),
`:5900` VNC (internal).

## Layout

```
openbox/Containerfile    pure-X11 image (Xvfb/openbox/x11vnc/noVNC + worker)
openbox/entrypoint.sh    starts agent-worker, then the X11 stack (background)
labwc/Containerfile      pure-Wayland image (labwc/wayvnc/noVNC + worker)
labwc/entrypoint.sh      starts agent-worker, then the Wayland stack (background)
build.sh                 build+push one flavor (buildctl → skopeo → registry)
```

## Build

```sh
scripts/build-all.sh                          # dist/agent-worker-linux-amd64
./agent-toolchain/desktop/build.sh openbox    # -> sandbox/sandbox-desktop:openbox
./agent-toolchain/desktop/build.sh labwc      # -> sandbox/sandbox-desktop:labwc
```

## Display env reaches jobs

The worker's job environment **inherits** the worker's own environment (see the
repo README), so `DISPLAY` (openbox) / `WAYLAND_DISPLAY` + `XDG_RUNTIME_DIR`
(labwc) are visible to jobs — a GUI program run from a job appears on the
desktop with no extra plumbing.
