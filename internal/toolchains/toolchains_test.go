package toolchains

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// tarGz builds a single-root tar.gz: root/<files...>.
func tarGz(t *testing.T, root string, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	dir := root + "/"
	if err := tw.WriteHeader(&tar.Header{Name: dir, Typeflag: tar.TypeDir, Mode: 0o755}); err != nil {
		t.Fatal(err)
	}
	for name, body := range files {
		b := []byte(body)
		if err := tw.WriteHeader(&tar.Header{Name: dir + name, Typeflag: tar.TypeReg, Mode: 0o755, Size: int64(len(b))}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(b); err != nil {
			t.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func zipSingle(t *testing.T, name, body string) []byte {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	w, err := zw.Create(name)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write([]byte(body)); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func sha(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

// serveIndex starts an httptest server hosting the given blobs and returns the
// index URL plus the blobs' base URL.
func serveIndex(t *testing.T, blobs map[string][]byte, index func(base string) string) (string, string) {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/blobs/", func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/blobs/")
		b, ok := blobs[name]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(b)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	mux.HandleFunc("/index.json", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(index(srv.URL)))
	})
	return srv.URL + "/index.json", srv.URL
}

func TestParseIndexStrict(t *testing.T) {
	cases := map[string]string{
		"no schema":  `{"toolchains":{"go":{"versions":{"1.0":{"artifacts":[{"url":"u","sha256":"a","format":"tar.gz"}]}}}}}`,
		"no sha256":  `{"schema":1,"toolchains":{"go":{"versions":{"1.0":{"artifacts":[{"url":"u","format":"tar.gz"}]}}}}}`,
		"bad format": `{"schema":1,"toolchains":{"go":{"versions":{"1.0":{"artifacts":[{"url":"u","sha256":"a","format":"rar"}]}}}}}`,
		"no arts":    `{"schema":1,"toolchains":{"go":{"versions":{"1.0":{"artifacts":[]}}}}}`,
	}
	for name, doc := range cases {
		if _, err := ParseIndex([]byte(doc)); err == nil {
			t.Errorf("%s: expected error, got nil", name)
		}
	}
}

func TestEnsureTarGz(t *testing.T) {
	blob := tarGz(t, "go", map[string]string{"bin/go": "#!/bin/sh\necho go\n"})
	idxURL, _ := serveIndex(t, map[string][]byte{"go.tgz": blob}, func(base string) string {
		doc := map[string]any{"schema": 1, "toolchains": map[string]any{
			"go": map[string]any{"versions": map[string]any{
				"1.27.1": map[string]any{"artifacts": []any{map[string]any{
					"url": base + "/blobs/go.tgz", "sha256": sha(blob), "format": "tar.gz", "strip": 1, "bin": "bin",
				}}},
			}},
		}}
		b, _ := json.Marshal(doc)
		return string(b)
	})

	root := t.TempDir()
	in := New(root, idxURL, http.DefaultClient, nil)
	bins, err := in.Ensure(context.Background(), []Spec{{Name: "go", Version: "1.27.1"}})
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(root, "go", "1.27.1", "bin")
	if len(bins) != 1 || bins[0] != want {
		t.Fatalf("bins=%v want [%s]", bins, want)
	}
	if _, err := os.Stat(filepath.Join(want, "go")); err != nil {
		t.Fatalf("binary not extracted: %v", err)
	}
	// Idempotent: second call returns the same dirs, no error.
	if bins2, err := in.Ensure(context.Background(), []Spec{{Name: "go", Version: "1.27.1"}}); err != nil || len(bins2) != 1 {
		t.Fatalf("second ensure: bins=%v err=%v", bins2, err)
	}
}

func TestEnsureShaMismatch(t *testing.T) {
	blob := tarGz(t, "go", map[string]string{"bin/go": "x"})
	idxURL, _ := serveIndex(t, map[string][]byte{"go.tgz": blob}, func(base string) string {
		doc := map[string]any{"schema": 1, "toolchains": map[string]any{
			"go": map[string]any{"versions": map[string]any{
				"1.27.1": map[string]any{"artifacts": []any{map[string]any{
					"url": base + "/blobs/go.tgz", "sha256": strings.Repeat("0", 64), "format": "tar.gz", "strip": 1, "bin": "bin",
				}}},
			}},
		}}
		b, _ := json.Marshal(doc)
		return string(b)
	})
	root := t.TempDir()
	in := New(root, idxURL, http.DefaultClient, nil)
	if _, err := in.Ensure(context.Background(), []Spec{{Name: "go", Version: "1.27.1"}}); err == nil {
		t.Fatal("expected sha mismatch error")
	}
	// No half install: the version dir must not exist.
	if _, err := os.Stat(filepath.Join(root, "go", "1.27.1")); !os.IsNotExist(err) {
		t.Fatalf("half install left behind: %v", err)
	}
}

func TestEnsureRequires(t *testing.T) {
	jdk := tarGz(t, "jdk-25", map[string]string{"bin/java": "java"})
	kotlin := zipSingle(t, "kotlinc/bin/kotlinc", "kotlinc")
	idxURL, _ := serveIndex(t, map[string][]byte{"jdk.tgz": jdk, "kotlin.zip": kotlin}, func(base string) string {
		doc := map[string]any{"schema": 1, "toolchains": map[string]any{
			"java25": map[string]any{"versions": map[string]any{
				"25.0.4": map[string]any{"artifacts": []any{map[string]any{
					"url": base + "/blobs/jdk.tgz", "sha256": sha(jdk), "format": "tar.gz", "strip": 1, "bin": "bin"}}},
			}},
			"kotlin": map[string]any{"requires": []string{"java25"}, "versions": map[string]any{
				"2.4.20": map[string]any{"artifacts": []any{map[string]any{
					"url": base + "/blobs/kotlin.zip", "sha256": sha(kotlin), "format": "zip", "strip": 1, "bin": "bin"}}},
			}},
		}}
		b, _ := json.Marshal(doc)
		return string(b)
	})
	root := t.TempDir()
	in := New(root, idxURL, http.DefaultClient, nil)
	bins, err := in.Ensure(context.Background(), []Spec{{Name: "kotlin", Version: "2.4.20"}})
	if err != nil {
		t.Fatal(err)
	}
	// The requires (java25) must be pulled in automatically.
	if _, err := os.Stat(filepath.Join(root, "java25", "25.0.4", "bin", "java")); err != nil {
		t.Fatalf("required java25 not installed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "kotlin", "2.4.20", "bin", "kotlinc")); err != nil {
		t.Fatalf("kotlin not installed: %v", err)
	}
	if len(bins) != 2 {
		t.Fatalf("bins=%v want 2 (kotlin + java25)", bins)
	}
}

func TestEnsureInstallStep(t *testing.T) {
	blob := tarGz(t, "rust", map[string]string{"install.sh": "#!/bin/sh\ntouch \"$1/marker\"\n"})
	idxURL, _ := serveIndex(t, map[string][]byte{"rust.tgz": blob}, func(base string) string {
		doc := map[string]any{"schema": 1, "toolchains": map[string]any{
			"rust": map[string]any{"versions": map[string]any{
				"1.98.1": map[string]any{
					"artifacts": []any{map[string]any{
						"url": base + "/blobs/rust.tgz", "sha256": sha(blob), "format": "tar.gz", "strip": 1}},
					"install": []string{"/bin/sh", "./install.sh", "{root}"},
				},
			}},
		}}
		b, _ := json.Marshal(doc)
		return string(b)
	})
	root := t.TempDir()
	in := New(root, idxURL, http.DefaultClient, nil)
	if _, err := in.Ensure(context.Background(), []Spec{{Name: "rust", Version: "1.98.1"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "rust", "1.98.1", "marker")); err != nil {
		t.Fatalf("install step did not run: %v", err)
	}
}

func TestParseSpecs(t *testing.T) {
	specs, err := ParseSpecs("go=1.27.1, node=26.9.0\n# comment\n\npython=3.14.7")
	if err != nil {
		t.Fatal(err)
	}
	if len(specs) != 3 || specs[0] != (Spec{"go", "1.27.1"}) || specs[2] != (Spec{"python", "3.14.7"}) {
		t.Fatalf("specs=%v", specs)
	}
	if _, err := ParseSpecs("garbage"); err == nil {
		t.Fatal("expected error for spec without version")
	}
}

func TestGreatestVersion(t *testing.T) {
	v := map[string]Version{"1.9.0": {}, "1.10.0": {}, "1.27.1": {}}
	got, err := greatestVersion(v)
	if err != nil || got != "1.27.1" {
		t.Fatalf("got %q err %v", got, err)
	}
}
