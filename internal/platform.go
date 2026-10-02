package internal

import (
	"os"
	"runtime"
	"strings"
)

func goos() string   { return runtime.GOOS }
func goarch() string { return runtime.GOARCH }

// distroID reads /etc/os-release's ID (e.g. "debian", "alpine", "ubuntu"),
// lower-cased. "" when the file is absent or has no ID (e.g. windows/macos,
// or scratch images).
func distroID() string {
	b, err := os.ReadFile("/etc/os-release")
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if v, ok := strings.CutPrefix(line, "ID="); ok {
			return strings.ToLower(strings.Trim(v, `"`))
		}
	}
	return ""
}

// homeDir is the worker user's home (where `~` resolves), or "" when the
// platform has none.
func homeDir() string {
	h, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return h
}
