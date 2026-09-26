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
#   3. boot-fetch the xa11y computer-use CLI from http://host.lan:8090/xa11y
#      and grant it the Accessibility (TCC) permission (SIP is off in this
#      image, so the TCC db is writable) — done as root before the worker
#   4. start agent-worker inside docker's GUI session
set -Eeuo pipefail

WROOT=/Users/docker
BIN="$WROOT/agent-worker-darwin"
DL="$WROOT/agent-worker-darwin.dl"
WS="$WROOT/ewws"
XA="$WROOT/xa11y"
XA_BIN=/usr/local/bin/xa11y
TCC="/Library/Application Support/com.apple.TCC/TCC.db"

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
# The CLI is a self-contained Mach-O binary (built from source; needs only
# system frameworks — no CLT, no Python). Install it and grant Accessibility so
# it can read/drive other apps' accessibility trees. Failures only disable
# computer-use, not the worker.
if curl -s -m 60 -o "$XA.dl" http://host.lan:8090/xa11y 2>/dev/null && [ -s "$XA.dl" ]; then
  chmod 755 "$XA.dl"
  mv -f "$XA.dl" "$XA" 2>/dev/null || true
fi
# /usr/local/bin may not exist on a fresh disk; create it and link xa11y.
mkdir -p /usr/local/bin 2>/dev/null || true
[ -x "$XA" ] && ln -sf "$XA" "$XA_BIN" 2>/dev/null || true

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

# --- grant TCC (Accessibility + ScreenCapture), now that both paths exist ---
# macOS attributes the permission to the RESPONSIBLE process: for a job that is
# the worker (which forks xa11y), and for xa11y itself when run directly. Grant
# all three paths. Only possible with SIP off (the TCC db is SIP-protected).
if [ "$(id -un)" = "root" ] && [ -w "$TCC" ] && [ -x /usr/bin/sqlite3 ]; then
  for client in "$XA" "$XA_BIN" "$BIN"; do
    for svc in kTCCServiceAccessibility kTCCServiceScreenCapture; do
      sqlite3 "$TCC" "INSERT OR REPLACE INTO access(service,client,client_type,auth_value,auth_reason,auth_version,csreq,policy_id,indirect_object_identifier_type,indirect_object_identifier,indirect_object_code_identity,flags,last_modified) VALUES('$svc','$client',1,2,4,1,NULL,NULL,0,'UNUSED',NULL,0,strftime('%s','now'));" 2>/dev/null || true
    done
  done
  launchctl stop com.apple.tccd 2>/dev/null || true
fi

# The daemon path runs as root; hand the workspace + binaries to docker so the
# worker (which runs as docker) can write its sqlite DB.
if [ "$(id -un)" = "root" ]; then
  chown -R docker:staff "$WS" 2>/dev/null || true
  chown docker:staff "$BIN" "$XA" 2>/dev/null || true
fi

# Jobs inherit the worker's environment, so put xa11y on PATH here — a
# launchd-spawned process gets only the bare system PATH.
export PATH="/usr/local/bin:$PATH"

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
