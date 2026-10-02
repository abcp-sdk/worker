package internal

import (
	"net"
	"strconv"
	"testing"
)

func TestProbeCapabilitiesDesktop(t *testing.T) {
	t.Setenv("WORKER_NOVNC_PORT", "0") // skip the dial
	t.Setenv("DISPLAY", "")
	t.Setenv("WAYLAND_DISPLAY", "")
	if c := probeCapabilities(); c.Desktop || c.Display != "" {
		t.Fatalf("no display env must yield no desktop, got %+v", c)
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

func TestProbeCapabilitiesNovnc(t *testing.T) {
	// A listener on an ephemeral port must be detected via the dial probe.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()
	port := ln.Addr().(*net.TCPAddr).Port
	t.Setenv("WORKER_NOVNC_PORT", strconv.Itoa(port))
	c := probeCapabilities()
	if !c.Novnc || int(c.NovncPort) != port {
		t.Fatalf("listening port must be detected, got %+v", c)
	}
	// A closed port must NOT be detected.
	_ = ln.Close()
	c = probeCapabilities()
	if c.Novnc {
		t.Fatalf("closed port must not be detected, got %+v", c)
	}
}

func TestNovncProbePort(t *testing.T) {
	t.Setenv("WORKER_NOVNC_PORT", "")
	if p := novncProbePort(); p != 6080 {
		t.Fatalf("default = %d, want 6080", p)
	}
	t.Setenv("WORKER_NOVNC_PORT", "0")
	if p := novncProbePort(); p != 0 {
		t.Fatalf("0 must disable the probe, got %d", p)
	}
}
