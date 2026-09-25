#!/usr/bin/env bash
# agent-worker desktop entrypoint — PURE Wayland flavor (labwc + wayvnc).
#
#   agent-worker :48080                    (started FIRST, see below)
#   labwc (headless)  ->  wayvnc :5900  ->  websockify :6080 (noVNC)
#
# labwc is a wlroots compositor; WLR_BACKENDS=headless gives it an output with
# no real display. wayvnc exports that output over RFB. Everything runs as root
# with tini as PID 1.
#
# ORDER MATTERS: the worker comes up before the compositor. The gateway's
# CreateSandbox waits only 60s for :48080 to accept. WAYLAND_DISPLAY is preset
# to wayland-0 (the name labwc picks in a clean container) BEFORE the worker
# starts, because jobs inherit the worker's environment; the background
# bring-up then asserts the socket really is wayland-0.
set -Eeuo pipefail

SCREEN_PORT="${SCREEN_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5900}"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
mkdir -p "$XDG_RUNTIME_DIR" /workspace /data
chmod 700 "$XDG_RUNTIME_DIR"

# Screen-stack PIDs live in pid files: the stack comes up in a background
# subshell, so its variables would not reach the signal handler.
cleanup() {
  kill "${WORKER_PID:-}" \
       "$(cat /tmp/websockify.pid 2>/dev/null)" \
       "$(cat /tmp/wayvnc.pid 2>/dev/null)" \
       "$(cat /tmp/foot.pid 2>/dev/null)" \
       "$(cat /tmp/labwc.pid 2>/dev/null)" 2>/dev/null || true
}
trap cleanup TERM INT

# --- agent-worker FIRST (foreground process; owns the container lifetime) --
echo "desktop[wayland]: starting agent-worker on :${WORKER_PORT:-48080} (WAYLAND_DISPLAY=${WAYLAND_DISPLAY})"
agent-worker &
WORKER_PID=$!

# --- compositor + sharing in the background (never blocks the worker) -----
bring_up_desktop() {
  echo "desktop[wayland]: starting labwc (headless)"
  WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 labwc >/tmp/labwc.log 2>&1 &
  echo $! > /tmp/labwc.pid

  # Wait for the wayland socket (labwc names it wayland-<n>; usually wayland-0).
  for _ in $(seq 1 100); do
    ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -q '^wayland' && break
    sleep 0.2
  done
  WL_SOCK="$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep '^wayland' | head -1 || true)"
  if [ -z "$WL_SOCK" ]; then
    echo "desktop[wayland]: compositor failed to start" >&2
    cat /tmp/labwc.log >&2 || true
    return 0
  fi
  # The worker (and thus its jobs) already inherited WAYLAND_DISPLAY. A clean
  # container always yields wayland-0; warn loudly if that assumption breaks.
  if [ "$WL_SOCK" != "$WAYLAND_DISPLAY" ]; then
    echo "desktop[wayland]: WARNING socket is ${WL_SOCK}, jobs inherited ${WAYLAND_DISPLAY}" >&2
  fi

  # --- a terminal so the desktop is not empty ---------------------------
  foot >/tmp/foot.log 2>&1 &
  echo $! > /tmp/foot.pid

  # --- screen sharing ---------------------------------------------------
  echo "desktop[wayland]: wayvnc :${VNC_PORT}"
  wayvnc 0.0.0.0 "${VNC_PORT}" >/tmp/wayvnc.log 2>&1 &
  echo $! > /tmp/wayvnc.pid

  echo "desktop[wayland]: noVNC on :${SCREEN_PORT}"
  websockify --web /usr/share/novnc "${SCREEN_PORT}" "localhost:${VNC_PORT}" \
    >/tmp/websockify.log 2>&1 &
  echo $! > /tmp/websockify.pid
}
bring_up_desktop &

# The worker is PID-of-record: when it exits, tear the desktop down.
wait "$WORKER_PID"
