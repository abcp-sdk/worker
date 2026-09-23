#!/usr/bin/env bash
# agent-worker desktop entrypoint — PURE X11 flavor (Xvfb + openbox + x11vnc).
#
#   Xvfb :99  ->  openbox  ->  x11vnc :5900  ->  websockify :6080 (noVNC)
#   agent-worker :48080
#
# Everything runs as root. tini is PID 1, so this script only needs to start the
# stack and wait on the worker; on TERM it tears the children down.
set -Eeuo pipefail

DISPLAY_NUM="${DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"
GEOMETRY="${SCREEN_GEOMETRY:-1280x720x24}"
SCREEN_PORT="${SCREEN_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5900}"

mkdir -p /workspace /data

# --- virtual X server -----------------------------------------------------
echo "desktop[x11]: starting Xvfb on ${DISPLAY} (${GEOMETRY})"
Xvfb "${DISPLAY}" -screen 0 "${GEOMETRY}" -ac -nolisten tcp >/tmp/xvfb.log 2>&1 &
XVFB_PID=$!

for _ in $(seq 1 100); do
  [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ] && break
  sleep 0.2
done

# --- window manager + a terminal so the desktop is not empty --------------
echo "desktop[x11]: starting openbox"
openbox >/tmp/openbox.log 2>&1 &
OB_PID=$!
xterm -geometry 100x28+20+20 -title "agent-worker" >/tmp/xterm.log 2>&1 &
XTERM_PID=$!

# --- screen sharing -------------------------------------------------------
echo "desktop[x11]: x11vnc :${VNC_PORT}"
x11vnc -display "${DISPLAY}" -rfbport "${VNC_PORT}" -forever -shared -nopw -quiet \
  >/tmp/x11vnc.log 2>&1 &
VNC_PID=$!

echo "desktop[x11]: noVNC on :${SCREEN_PORT}"
websockify --web /usr/share/novnc "${SCREEN_PORT}" "localhost:${VNC_PORT}" \
  >/tmp/websockify.log 2>&1 &
WS_PID=$!

cleanup() {
  kill "${WORKER_PID:-}" "$WS_PID" "$VNC_PID" "$XTERM_PID" "$OB_PID" "$XVFB_PID" 2>/dev/null || true
}
trap cleanup TERM INT

# --- agent-worker (foreground; jobs inherit DISPLAY from here) ------------
echo "desktop[x11]: starting agent-worker on :${WORKER_PORT:-48080}"
agent-worker &
WORKER_PID=$!

wait "$WORKER_PID"
