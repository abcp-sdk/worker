#!/usr/bin/env bash
# agent-worker desktop entrypoint — PURE Wayland flavor (labwc + wayvnc).
#
#   labwc (headless)  ->  wayvnc :5900  ->  websockify :6080 (noVNC)
#   agent-worker :48080
#
# labwc is a wlroots compositor; WLR_BACKENDS=headless gives it an output with
# no real display. wayvnc exports that output over RFB. Everything runs as root
# with tini as PID 1.
set -Eeuo pipefail

SCREEN_PORT="${SCREEN_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5900}"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/xdg}"
mkdir -p "$XDG_RUNTIME_DIR" /workspace /data
chmod 700 "$XDG_RUNTIME_DIR"

# --- headless Wayland compositor ------------------------------------------
echo "desktop[wayland]: starting labwc (headless)"
WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 labwc >/tmp/labwc.log 2>&1 &
LABWC_PID=$!

# Wait for the wayland socket (labwc names it wayland-<n>; usually wayland-0).
for _ in $(seq 1 100); do
  ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -q '^wayland' && break
  sleep 0.2
done
WL_SOCK="$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep '^wayland' | head -1 || true)"
if [ -z "$WL_SOCK" ]; then
  echo "desktop[wayland]: compositor failed to start" >&2
  cat /tmp/labwc.log >&2 || true
  exit 1
fi
export WAYLAND_DISPLAY="$WL_SOCK"
echo "desktop[wayland]: WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"

# --- a terminal so the desktop is not empty -------------------------------
foot >/tmp/foot.log 2>&1 &
FOOT_PID=$!

# --- screen sharing -------------------------------------------------------
echo "desktop[wayland]: wayvnc :${VNC_PORT}"
wayvnc 0.0.0.0 "${VNC_PORT}" >/tmp/wayvnc.log 2>&1 &
VNC_PID=$!

echo "desktop[wayland]: noVNC on :${SCREEN_PORT}"
websockify --web /usr/share/novnc "${SCREEN_PORT}" "localhost:${VNC_PORT}" \
  >/tmp/websockify.log 2>&1 &
WS_PID=$!

cleanup() {
  kill "${WORKER_PID:-}" "$WS_PID" "$VNC_PID" "$FOOT_PID" "$LABWC_PID" 2>/dev/null || true
}
trap cleanup TERM INT

# --- agent-worker (foreground; jobs inherit WAYLAND_DISPLAY/XDG_RUNTIME_DIR) ---
echo "desktop[wayland]: starting agent-worker on :${WORKER_PORT:-48080}"
agent-worker &
WORKER_PID=$!

wait "$WORKER_PID"
