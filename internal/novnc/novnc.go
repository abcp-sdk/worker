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
// The target is deployment/image specific (there is no universal default):
//   - desktop images (openbox/labwc): the worker and noVNC/websockify share the
//     container → http://127.0.0.1:6080
//   - Windows/macOS VM images: the worker runs INSIDE the guest and reaches the
//     container's nginx (WEB_PORT 8006) via the QEMU gateway →
//     http://host.lan:8006
//
// so it is set with NOVNC_URL (empty = the mount is disabled / returns 404).
package novnc

import (
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"time"
)

// Prefix is the mount point of the proxy on the worker's origin.
const Prefix = "/novnc/"

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
