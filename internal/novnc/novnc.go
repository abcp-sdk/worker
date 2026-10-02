// Package novnc mounts the sandbox's noVNC/web-VNC endpoint at the worker's own
// origin, so the built-in control panel can embed the desktop in a page —
// WITHOUT exposing a second port/Service.
//
// It is a prefix-preserving reverse proxy: a request to /novnc/<x> is proxied
// to <target>/novnc/<x>. Keeping the SAME /novnc prefix upstream (rather than
// stripping it) means the noVNC assets' relative URLs AND its websocket path
// (/novnc/websocket) both resolve through this one mount with no path
// rewriting — and noVNC works unmodified.
//
// The upstream is the qemu VNC websocket (the VM container's nginx on
// WEB_PORT 8006, which bridges to qemu's VNC). The worker runs INSIDE the guest
// and reaches the container over the QEMU gateway (host.lan), so the target is
// a FIXED address — NOT probed. NOVNC_URL overrides it (e.g. a same-container
// desktop's websockify at http://127.0.0.1:6080).
package novnc

import (
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// Prefix is the mount point of the proxy on the worker's origin.
const Prefix = "/novnc/"

// DefaultTarget is the qemu VNC websocket endpoint. Fixed — never probed.
const DefaultTarget = "http://host.lan:8006"

// Target returns the noVNC upstream: an explicit NOVNC_URL, else DefaultTarget.
func Target() string {
	if v := strings.TrimSpace(os.Getenv("NOVNC_URL")); v != "" {
		return strings.TrimRight(v, "/")
	}
	return DefaultTarget
}

// Configured reports the explicitly-configured noVNC target and its port.
// ok=false unless NOVNC_URL is set — so a plain sandbox (which has no noVNC)
// does NOT claim one, while a VM deployment declares it. The proxy's default
// (DefaultTarget) is still used for the mount even when ok=false.
func Configured() (string, int, bool) {
	v := strings.TrimSpace(os.Getenv("NOVNC_URL"))
	if v == "" {
		return "", 0, false
	}
	v = strings.TrimRight(v, "/")
	u, err := url.Parse(v)
	if err != nil {
		return v, 0, true
	}
	p, _ := strconv.Atoi(u.Port())
	return v, p, true
}

// Handler proxies /novnc/* to target (e.g. http://127.0.0.1:6080). An empty or
// unparseable target yields a handler that 404s, so the mount is a no-op when
// noVNC is not configured.
func Handler(target string) http.Handler {
	target = strings.TrimRight(strings.TrimSpace(target), "/")
	u, err := url.Parse(target)
	if target == "" || err != nil || u.Host == "" {
		return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			http.Error(w, "noVNC not configured", http.StatusNotFound)
		})
	}
	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			// Preserve the /novnc prefix (see the package comment).
			r.SetURL(u)
			r.Out.URL.Path = singleJoiningSlash(u.Path, r.In.URL.Path)
			r.Out.URL.RawQuery = r.In.URL.RawQuery
			r.SetXForwarded()
		},
		// Stream: no response buffering (the websocket upgrade and the VNC
		// frame stream must flow immediately). ReverseProxy handles the
		// Connection/Upgrade handshake itself.
		FlushInterval: -1,
		Transport:     transport(),
	}
	return proxy
}

// transport returns a transport with sane timeouts. ResponseHeaderTimeout and
// IdleConnTimeout are set, but no overall timeout — a VNC session is long-lived.
func transport() http.RoundTripper {
	if t, ok := http.DefaultTransport.(*http.Transport); ok {
		cp := t.Clone()
		cp.ResponseHeaderTimeout = 30 * time.Second
		cp.IdleConnTimeout = 90 * time.Second
		return cp
	}
	return http.DefaultTransport
}

// singleJoiningSlash joins two URL paths with exactly one slash.
func singleJoiningSlash(a, b string) string {
	aslash := strings.HasSuffix(a, "/")
	bslash := strings.HasPrefix(b, "/")
	switch {
	case aslash && bslash:
		return a + b[1:]
	case !aslash && !bslash:
		if a == "" {
			return b
		}
		return a + "/" + b
	}
	return a + b
}
