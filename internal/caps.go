package internal

import (
	"net"
	"os"
	"os/exec"
	"strconv"
	"time"

	workerv1 "github.com/abcp-sdk/agent-worker/gen/worker/v1"
)

// probeCapabilities reports what the sandbox IMAGE can do. Everything is
// probed at request time (env, PATH, a TCP dial) so nothing is baked into the
// binary and a new toolchain/desktop image needs no worker change. It is
// best-effort: a false value means "not detected", never "impossible".
func probeCapabilities() *workerv1.Capabilities {
	c := &workerv1.Capabilities{Distro: distroID()}

	// Desktop: X11 (DISPLAY) or Wayland (WAYLAND_DISPLAY). Jobs inherit the
	// worker's env, so the same vars reach them.
	switch {
	case os.Getenv("WAYLAND_DISPLAY") != "":
		c.Desktop, c.Display = true, "wayland"
	case os.Getenv("DISPLAY") != "":
		c.Desktop, c.Display = true, "x11"
	}

	// noVNC: a web-VNC endpoint listening on 127.0.0.1 (same pod). Default
	// 6080; WORKER_NOVNC_PORT overrides the probe.
	if p := novncProbePort(); p > 0 {
		if dialable("127.0.0.1", p) {
			c.Novnc, c.NovncPort = true, int32(p)
		}
	}

	// xa11y: the accessibility CLI on PATH (X11 native-app automation).
	if _, err := exec.LookPath("xa11y"); err == nil {
		c.Xa11Y = true
	}
	return c
}

// novncProbePort is the port to probe for noVNC (default 6080; 0 disables the
// probe). WORKER_NOVNC_PORT overrides it.
func novncProbePort() int {
	if v := os.Getenv("WORKER_NOVNC_PORT"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return 6080
}

// dialable reports whether 127.0.0.1:port accepts a TCP connection quickly.
func dialable(host string, port int) bool {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), 300*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
