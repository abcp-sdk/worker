#!/usr/bin/env bash
set -Eeuo pipefail

# agent-worker Android sandbox entrypoint (run-only, non-persistent).
#
#   agent-worker :48080                    (started FIRST, see below)
#   emulator -no-window -wipe-data  ->  scrcpy-server  ->  bridge  -> browser
#   adb -> emulator-5554 (used by agent-worker jobs)
#
# The AVD is pre-built into the image. The guest is NOT persistent: the
# emulator always starts with -wipe-data, so every container start is a clean
# device (nothing survives a restart).
#
# ORDER MATTERS: the worker comes up before the (slow) emulator boot. The
# gateway's CreateSandbox waits only 60s for :48080 to accept, so the worker
# must listen immediately; the emulator and screen bridge are brought up in
# the background. Jobs that need the device must wait for it themselves
# (`adb wait-for-device` + `getprop sys.boot_completed`), since the worker is
# ready long before the guest is.

AVD="${ANDROID_AVD:-sandbox}"
MEM="${ANDROID_MEM:-4096}"
CPUS="${ANDROID_CPUS:-4}"
GPU="${ANDROID_GPU:-swiftshader_indirect}"
SCREEN_PORT="${SCREEN_PORT:-6080}"

export ANDROID_SDK_ROOT=/opt/android-sdk
export ANDROID_HOME=/opt/android-sdk
export ANDROID_AVD_HOME="${ANDROID_AVD_HOME:-/opt/android-avd}"
export PATH="/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:${PATH}"

mkdir -p /workspace

# Guest PIDs live in pid files: the guest comes up in a background subshell, so
# its variables would not reach the signal handler.
cleanup() {
  kill "${WORKER_PID:-}" \
       "$(cat /tmp/bridge.pid 2>/dev/null)" \
       "$(cat /tmp/emu.pid 2>/dev/null)" 2>/dev/null || true
}
trap cleanup TERM INT

# --- agent-worker FIRST (foreground process; owns the container lifetime) --
echo "android: starting agent-worker on :${WORKER_PORT:-48080}"
agent-worker &
WORKER_PID=$!

# --- emulator + bridge in the background (never blocks the worker) ---------
bring_up_guest() {
  echo "android: starting emulator (kvm, ${CPUS} vCPU, ${MEM} MB, gpu=${GPU}, wipe-data)"
  emulator -avd "$AVD" \
    -no-window -no-audio -no-boot-anim -no-snapshot -wipe-data \
    -gpu "$GPU" -accel on \
    -memory "$MEM" -cores "$CPUS" \
    -port 5554 \
    >/tmp/emulator.log 2>&1 &
  echo $! > /tmp/emu.pid

  echo "android: waiting for adbd + boot_completed"
  adb start-server >/dev/null 2>&1 || true
  booted=""
  for _ in $(seq 1 180); do
    bc="$(adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [ "$bc" = "1" ]; then booted="1"; break; fi
    sleep 5
  done

  if [ -z "$booted" ]; then
    echo "android: guest did not reach boot_completed" >&2
    tail -40 /tmp/emulator.log >&2 || true
    return 0
  fi
  echo "android: guest is up"

  # Keep the display awake and dismiss the keyguard so the view is the UI, not
  # the lock screen.
  adb -s emulator-5554 shell "svc power stayon true" >/dev/null 2>&1 || true
  adb -s emulator-5554 shell "wm dismiss-keyguard" >/dev/null 2>&1 || true

  # --- screen bridge (view-only; input is done via adb) -------------------
  export ANDROID_SERIAL="emulator-5554"
  export PORT="$SCREEN_PORT"
  export ADB="adb"
  export SCRCPY_SERVER=/opt/scrcpy-server.jar
  echo "android: starting screen bridge on :${SCREEN_PORT}"
  node /opt/bridge/server.js >/tmp/bridge.log 2>&1 &
  echo $! > /tmp/bridge.pid
}
bring_up_guest &

# The worker is PID-of-record: when it exits, tear the guest down.
wait "$WORKER_PID"
