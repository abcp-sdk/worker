#!/usr/bin/env bash
# agent-worker desktop entrypoint — PURE X11 flavor (Xvfb + openbox + x11vnc).
#
#   agent-worker :48080                    (started FIRST, see below)
#   Xvfb :99  ->  openbox  ->  x11vnc :5900  ->  websockify :6080 (noVNC)
#
# Everything runs as root. tini is PID 1, so this script only needs to start the
# stack and wait on the worker; on TERM it tears the children down.
#
# ORDER MATTERS: the worker comes up before the screen stack. The gateway's
# CreateSandbox waits only 60s for :48080 to accept; the X stack is fast, but
# starting the worker first makes readiness independent of it. Jobs inherit
# DISPLAY (see the repo README), so a GUI job still lands on the desktop.
set -Eeuo pipefail

DISPLAY_NUM="${DISPLAY_NUM:-99}"
export DISPLAY=":${DISPLAY_NUM}"
GEOMETRY="${SCREEN_GEOMETRY:-1280x720x24}"
SCREEN_PORT="${SCREEN_PORT:-6080}"
VNC_PORT="${VNC_PORT:-5900}"

mkdir -p /workspace /data

# Screen-stack PIDs live in pid files: the stack comes up in a background
# subshell, so its variables would not reach the signal handler.
cleanup() {
  kill "${WORKER_PID:-}" \
       "$(cat /tmp/websockify.pid 2>/dev/null)" \
       "$(cat /tmp/x11vnc.pid 2>/dev/null)" \
       "$(cat /tmp/xterm.pid 2>/dev/null)" \
       "$(cat /tmp/openbox.pid 2>/dev/null)" \
       "$(cat /tmp/xvfb.pid 2>/dev/null)" 2>/dev/null || true
}
trap cleanup TERM INT

# --- agent-worker FIRST (foreground process; owns the container lifetime) --
echo "desktop[x11]: starting agent-worker on :${WORKER_PORT:-48080}"
agent-worker &
WORKER_PID=$!

# --- screen stack in the background (never blocks the worker) -------------
bring_up_desktop() {
  # --- virtual X server -------------------------------------------------
  echo "desktop[x11]: starting Xvfb on ${DISPLAY} (${GEOMETRY})"
  Xvfb "${DISPLAY}" -screen 0 "${GEOMETRY}" -ac -nolisten tcp >/tmp/xvfb.log 2>&1 &
  echo $! > /tmp/xvfb.pid

  for _ in $(seq 1 100); do
    [ -S "/tmp/.X11-unix/X${DISPLAY_NUM}" ] && break
    sleep 0.2
  done

  # --- window manager + a terminal so the desktop is not empty ----------
  echo "desktop[x11]: starting openbox"
  openbox >/tmp/openbox.log 2>&1 &
  echo $! > /tmp/openbox.pid
  xterm -geometry 100x28+20+20 -title "agent-worker" >/tmp/xterm.log 2>&1 &
  echo $! > /tmp/xterm.pid

  # --- screen sharing ---------------------------------------------------
  echo "desktop[x11]: x11vnc :${VNC_PORT}"
  x11vnc -display "${DISPLAY}" -rfbport "${VNC_PORT}" -forever -shared -nopw -quiet \
    >/tmp/x11vnc.log 2>&1 &
  echo $! > /tmp/x11vnc.pid

  echo "desktop[x11]: noVNC on :${SCREEN_PORT}"
  websockify --web /usr/share/novnc "${SCREEN_PORT}" "localhost:${VNC_PORT}" \
    >/tmp/websockify.log 2>&1 &
  echo $! > /tmp/websockify.pid
}
bring_up_desktop &

# The worker is PID-of-record: when it exits, tear the desktop down.
wait "$WORKER_PID"
