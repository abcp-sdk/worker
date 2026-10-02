package internal

import "testing"

func TestProbeCapabilitiesDesktop(t *testing.T) {
	t.Setenv("NOVNC_URL", "") // no novnc declared
	t.Setenv("DISPLAY", "")
	t.Setenv("WAYLAND_DISPLAY", "")
	if c := probeCapabilities(); c.Desktop || c.Display != "" || c.Novnc {
		t.Fatalf("no display/novnc must yield none, got %+v", c)
	}
	t.Setenv("DISPLAY", ":99")
	if c := probeCapabilities(); !c.Desktop || c.Display != "x11" {
		t.Fatalf("DISPLAY must yield x11 desktop, got %+v", c)
	}
	t.Setenv("DISPLAY", "")
	t.Setenv("WAYLAND_DISPLAY", "wayland-0")
	if c := probeCapabilities(); !c.Desktop || c.Display != "wayland" {
		t.Fatalf("WAYLAND_DISPLAY must yield wayland desktop, got %+v", c)
	}
}

// TestProbeCapabilitiesNovnc: noVNC is reported ONLY when the deployment
// explicitly set NOVNC_URL (never probed).
func TestProbeCapabilitiesNovnc(t *testing.T) {
	t.Setenv("NOVNC_URL", "")
	if c := probeCapabilities(); c.Novnc {
		t.Fatalf("no NOVNC_URL must not report novnc, got %+v", c)
	}
	t.Setenv("NOVNC_URL", "http://host.lan:8006")
	if c := probeCapabilities(); !c.Novnc || c.NovncPort != 8006 {
		t.Fatalf("NOVNC_URL must report novnc:8006, got %+v", c)
	}
}
