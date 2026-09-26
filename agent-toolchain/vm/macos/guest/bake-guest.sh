#!/bin/bash
# Guest-side bake for the macOS image (run as root INSIDE the macOS guest).
#
# Goal: agent-worker runs inside docker's logged-in Aqua session (so GUI apps
# reach WindowServer) and docker may sudo without a password or TTY. The
# launcher boot-fetches the worker from host.lan:8090/worker.
set -Eeuo pipefail

WROOT=/Users/docker
SUDOERS=/etc/sudoers.d/agent-worker
LAUNCHER=$WROOT/worker-launch.sh
DAEMON=/Library/LaunchDaemons/com.agentworker.worker.plist
AGENT=$WROOT/Library/LaunchAgents/com.agentworker.worker.plist

mkdir -p "$WROOT/Library/LaunchAgents" "$WROOT/ws"
chown docker:staff "$WROOT/ws" "$WROOT/Library/LaunchAgents"

############ 1. passwordless sudo
cat > "$SUDOERS" <<'EOF'
Defaults:docker !requiretty
Defaults:docker !authenticate
docker ALL=(ALL) NOPASSWD: ALL
EOF
chown root:wheel "$SUDOERS"; chmod 440 "$SUDOERS"
visudo -c -f "$SUDOERS"

############ 2. launcher (installed from the image build context)
if [ -f /tmp/worker-launch.sh ]; then
  install -m 755 -o root -g wheel /tmp/worker-launch.sh "$LAUNCHER"
fi
chown root:wheel "$LAUNCHER"; chmod 755 "$LAUNCHER"

############ 3. LaunchDaemon: one-shot bootstrap/fallback (not KeepAlive)
cat > "$DAEMON" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.agentworker.worker</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/docker/worker-launch.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardOutPath</key><string>/Library/Logs/agent-worker.log</string>
    <key>StandardErrorPath</key><string>/Library/Logs/agent-worker.log</string>
</dict>
</plist>
EOF
chown root:wheel "$DAEMON"; chmod 644 "$DAEMON"

############ 4. LaunchAgent: the worker itself, inside docker's Aqua session
cat > "$AGENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.agentworker.worker</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/docker/worker-launch.sh</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>StandardOutPath</key><string>/Users/docker/ws/agent-worker-agent.log</string>
    <key>StandardErrorPath</key><string>/Users/docker/ws/agent-worker-agent.log</string>
</dict>
</plist>
EOF
chown docker:staff "$AGENT"; chmod 644 "$AGENT"

############ 5. auto-login docker so a real GUI session exists at boot
sysadminctl -autologin set -userName docker -password admin \
  -adminUser docker -adminPassword admin 2>&1 | tail -2 || true
defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string docker 2>/dev/null || true

############ 5b. xa11y computer-use CLI (install from a prebuilt wheel)
# xa11y ships a prebuilt abi3 macOS wheel that BUNDLES the CLI, so no Rust
# toolchain and no Xcode are needed to install it (unlike building from
# source). The wheel is placed at /tmp/xa11y.whl by the bake driver (fetched
# on the host); if absent, try PyPI. Installed for the docker user so its
# console script lands in docker's user bin, then symlinked into /usr/local/bin
# so a job's shell finds it on PATH.
XA11Y_BIN=""
if [ -f /tmp/xa11y.whl ]; then
  sudo -u docker /usr/bin/pip3 install --user --no-cache-dir /tmp/xa11y.whl 2>&1 | tail -2 || true
fi
for c in "$WROOT/Library/Python/3.9/bin/xa11y" "$WROOT/Library/Python/3.8/bin/xa11y"; do
  [ -x "$c" ] && XA11Y_BIN="$c" && break
done
if [ -n "$XA11Y_BIN" ]; then
  ln -sf "$XA11Y_BIN" /usr/local/bin/xa11y
  echo "xa11y installed: $XA11Y_BIN"
else
  echo "WARNING: xa11y wheel not installed (computer-use disabled)"
fi

# The Accessibility (TCC) permission the CLI needs cannot be granted from a
# script while SIP is on (the TCC db is SIP-protected). The bake driver must
# boot the guest with csr-active-config=0x7f (see vendor/assets/config.plist
# NVRAM/csr-active-config) and then insert the grant below; this script does it
# only if the db is writable (i.e. SIP is off).
TCC="/Library/Application Support/com.apple.TCC/TCC.db"
if sqlite3 "$TCC" "SELECT 1" >/dev/null 2>&1; then
  # Grant Accessibility to the python interpreter that runs xa11y (the client
  # process TCC attributes the request to).
  PY="$(head -1 "$XA11Y_BIN" 2>/dev/null | sed 's/^#!//')"
  for client in "${PY:-/usr/bin/python3}" /usr/local/bin/xa11y; do
    sqlite3 "$TCC" "INSERT OR REPLACE INTO access(service,client,client_type,auth_value,auth_reason,auth_version,csreq,policy_id,indirect_object_identifier_type,indirect_object_identifier,indirect_object_code_identity,flags,last_modified) VALUES('kTCCServiceAccessibility','$client',1,2,4,1,NULL,NULL,0,'UNUSED',NULL,0,strftime('%s','now'));" 2>/dev/null \
      && echo "TCC Accessibility granted to $client" \
      || echo "WARNING: could not grant TCC to $client"
  done
  launchctl stop com.apple.tccd 2>/dev/null || true
else
  echo "NOTE: TCC db not writable (SIP on) — Accessibility must be granted with SIP off"
fi

############ 6. verify
echo "== sudoers =="; visudo -c -f "$SUDOERS"
echo "== autologin =="; sysadminctl -autologin status 2>&1 | tail -1
echo "== daemon =="; plutil -lint "$DAEMON"
echo "== agent =="; plutil -lint "$AGENT"
echo "== launcher =="; ls -la "$LAUNCHER"
echo "== xa11y =="; ls -la /usr/local/bin/xa11y 2>/dev/null || echo "(not installed)"
echo BAKE_GUEST_OK
