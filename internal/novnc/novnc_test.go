package novnc

import (
	"bufio"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// TestProxyPreservesPrefix verifies /novnc/<x> is proxied to <target>/novnc/<x>
// (the same prefix), so noVNC's relative assets + its /novnc/websocket resolve
// without rewriting.
func TestProxyPreservesPrefix(t *testing.T) {
	var gotPath, gotQuery string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotQuery = r.URL.RawQuery
		_, _ = io.WriteString(w, "vnc-ok")
	}))
	t.Cleanup(upstream.Close)

	h := Handler(upstream.URL)
	req := httptest.NewRequest(http.MethodGet, "/novnc/vnc.html?autoconnect=1", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || rec.Body.String() != "vnc-ok" {
		t.Fatalf("status=%d body=%q", rec.Code, rec.Body.String())
	}
	if gotPath != "/novnc/vnc.html" {
		t.Fatalf("upstream path = %q, want /novnc/vnc.html", gotPath)
	}
	if gotQuery != "autoconnect=1" {
		t.Fatalf("upstream query = %q", gotQuery)
	}
}

// TestWebsocketUpgrade verifies the Upgrade handshake is passed through, over
// REAL servers (a ResponseRecorder cannot hijack, so it cannot carry a 101).
func TestWebsocketUpgrade(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Upgrade") != "websocket" {
			t.Errorf("upstream did not see the Upgrade header: %q", r.Header.Get("Upgrade"))
		}
		hj, ok := w.(http.Hijacker)
		if !ok {
			t.Error("upstream ResponseWriter is not a Hijacker")
			return
		}
		conn, _, err := hj.Hijack()
		if err != nil {
			t.Errorf("hijack: %v", err)
			return
		}
		defer func() { _ = conn.Close() }()
		_, _ = conn.Write([]byte("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"))
	}))
	t.Cleanup(upstream.Close)

	front := httptest.NewServer(Handler(upstream.URL))
	t.Cleanup(front.Close)

	conn, err := net.DialTimeout("tcp", strings.TrimPrefix(front.URL, "http://"), 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close() }()
	_, _ = conn.Write([]byte("GET /novnc/websocket HTTP/1.1\r\nHost: x\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"))
	line, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil {
		t.Fatalf("read status line: %v", err)
	}
	if !strings.Contains(line, "101") {
		t.Fatalf("status line = %q, want 101", strings.TrimSpace(line))
	}
}

// TestNotConfigured: an empty target 404s (the mount is a no-op).
func TestNotConfigured(t *testing.T) {
	for _, target := range []string{"", "not-a-url"} {
		rec := httptest.NewRecorder()
		Handler(target).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/novnc/", nil))
		if rec.Code != http.StatusNotFound {
			t.Fatalf("target %q: status = %d, want 404", target, rec.Code)
		}
	}
}

// TestTargetLocksQemuVNC: the default is the qemu VNC websocket, never probed;
// NOVNC_URL overrides it.
func TestTargetLocksQemuVNC(t *testing.T) {
	t.Setenv("NOVNC_URL", "")
	if got := Target(); got != DefaultTarget {
		t.Fatalf("default target = %q, want %q", got, DefaultTarget)
	}
	if DefaultTarget != "http://host.lan:8006" {
		t.Fatalf("DefaultTarget = %q, want the qemu VNC endpoint", DefaultTarget)
	}
	t.Setenv("NOVNC_URL", "http://127.0.0.1:6080/")
	if got := Target(); got != "http://127.0.0.1:6080" {
		t.Fatalf("override target = %q", got)
	}
}

// TestConfigured: only an explicit NOVNC_URL is "configured" (capabilities).
func TestConfigured(t *testing.T) {
	t.Setenv("NOVNC_URL", "")
	if _, _, ok := Configured(); ok {
		t.Fatal("unset NOVNC_URL must not be configured")
	}
	t.Setenv("NOVNC_URL", "http://host.lan:8006")
	if _, port, ok := Configured(); !ok || port != 8006 {
		t.Fatalf("configured = %v port=%d", ok, port)
	}
}
