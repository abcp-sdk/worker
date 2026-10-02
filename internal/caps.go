package internal

import (
	"os"
	"os/exec"

	workerv1 "github.com/abcp-sdk/agent-worker/gen/worker/v1"
	"github.com/abcp-sdk/agent-worker/internal/novnc"
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

	// noVNC: reported only when the deployment EXPLICITLY configured NOVNC_URL
	// (a VM manifest sets it; a plain sandbox does not). Not probed.
	if _, port, ok := novnc.Configured(); ok {
		c.Novnc, c.NovncPort = true, int32(port)
	}

	// xa11y: the accessibility CLI on PATH (X11 native-app automation).
	if _, err := exec.LookPath("xa11y"); err == nil {
		c.Xa11Y = true
	}
	return c
}
