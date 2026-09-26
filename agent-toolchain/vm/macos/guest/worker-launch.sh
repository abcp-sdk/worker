#!/bin/bash
# AgentWorker macOS guest launcher.
#
# Runs in two places (same script):
#   * as `docker` via the LaunchAgent in the Aqua session (normal path), and
#   * as root via the one-shot LaunchDaemon (bootstrap/fallback).
#
# Responsibilities:
#   1. fetch the pod-provided WORKER_TOKEN from http://host.lan:8090/token
#   2. boot-fetch the current agent-worker binary from
#      http://host.lan:8090/worker (so a worker upgrade is an image change,
#      not a golden-disk change), falling back to the baked copy
#   3. start agent-worker inside docker's GUI session
set -Eeuo pipefail

WROOT=/Users/docker
BIN="$WROOT/agent-worker-darwin"
DL="$WROOT/agent-worker-darwin.dl"
WS="$WROOT/ewws"

TOKEN=""
for _ in $(seq 1 60); do
  if TOKEN=$(curl -s -m 2 http://host.lan:8090/token 2>/dev/null); then
    TOKEN=$(printf '%s' "$TOKEN" | tr -d '\r\n')
    break
  fi
  sleep 1
done
[ -n "$TOKEN" ] && export WORKER_TOKEN="$TOKEN"

mkdir -p "$WS"
cd "$WROOT"

# --- boot-fetch xa11y (best effort) ---------------------------------------
# The xa11y CLI ships as a prebuilt abi3 wheel (no Rust/Xcode needed). Fetch it
# from the pod's nginx (:8090 /xa11y.whl) and install it for docker if the CLI
# is not already present. Failures only disable computer-use, not the worker.
if [ ! -x /usr/local/bin/xa11y ] && [ ! -x "$WROOT/Library/Python/3.9/bin/xa11y" ]; then
  WHL=/tmp/xa11y.whl
  if curl -s -m 60 -o "$WHL" http://host.lan:8090/xa11y.whl 2>/dev/null && [ -s "$WHL" ]; then
    sudo -u docker /usr/bin/pip3 install --user --no-cache-dir "$WHL" >/tmp/xa11y-install.log 2>&1 || true
    for c in "$WROOT/Library/Python/3.9/bin/xa11y" "$WROOT/Library/Python/3.8/bin/xa11y"; do
      [ -x "$c" ] && ln -sf "$c" /usr/local/bin/xa11y 2>/dev/null && break
    done
  fi
fi

# --- boot-fetch the worker (best effort; keep the disk copy) --------------
if curl -s -m 30 -o "$DL" http://host.lan:8090/worker 2>/dev/null; then
  if [ -s "$DL" ] && [ "$(stat -f%z "$DL" 2>/dev/null || echo 0)" -gt 1000000 ]; then
    chmod 755 "$DL"
    if ! mv -f "$DL" "$BIN" 2>/dev/null; then BIN="$DL"; fi
  else
    rm -f "$DL"
  fi
fi
[ -x "$BIN" ] || BIN="$WROOT/agent-worker-v0.5.2"

# The daemon path runs as root; hand the workspace + binaries to docker so the
# worker (which runs as docker) can write its sqlite DB.
if [ "$(id -un)" = "root" ]; then
  chown -R docker:staff "$WS" 2>/dev/null || true
  chown docker:staff "$BIN" 2>/dev/null || true
fi

# Jobs inherit the worker's environment, so put xa11y (and the pip user bin) on
# PATH here — a launchd-spawned process gets only the bare system PATH.
export PATH="/usr/local/bin:$WROOT/Library/Python/3.9/bin:$PATH"

# Agent path: already inside docker's Aqua session.
if [ "$(id -un)" = "docker" ]; then
  exec "$BIN" -addr 0.0.0.0:48080 -workspace "$WS" -db "$WS/jobs.db"
fi

# Daemon path: wait for the logged-in session, then hand off to the agent.
for _ in $(seq 1 150); do
  if launchctl print gui/501 >/dev/null 2>&1; then
    if launchctl asuser 501 launchctl kickstart -k gui/501/com.agentworker.worker 2>/dev/null; then
      exit 0
    fi
  fi
  sleep 2
done

# No GUI session ever appeared: run headless as docker (old behaviour).
exec sudo -u docker --preserve-env=WORKER_TOKEN,PATH "$BIN" \
  -addr 0.0.0.0:48080 -workspace "$WS" -db "$WS/jobs.db"
