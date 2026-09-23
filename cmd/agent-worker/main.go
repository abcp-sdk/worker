// Command agent-worker is the sandbox worker: a single static binary exposing
// the WorkerService Connect API. It runs (a) as a plain host process on
// windows/macos/linux (the forgejo-runner desktop model: register and dial
// out), and (b) as the worker injected into cluster sandboxes (WORKER_PORT
// pins the listen port there; the legacy default was 8080, sandboxes pin
// 48080).
//
// Every command executes through the builtin mvdan.cc/sh/v3 interpreter —
// no passthrough, no fallback — so bash semantics are identical everywhere.
package main

import (
	"context"
	"flag"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"connectrpc.com/connect"
	workerv1connect "github.com/abcp-sdk/agent-worker/gen/worker/v1/workerv1connect"
	"github.com/abcp-sdk/agent-worker/internal"
	"github.com/abcp-sdk/agent-worker/internal/auth"
	"github.com/abcp-sdk/agent-worker/internal/filesvc"
	"github.com/abcp-sdk/agent-worker/internal/jobsvc"
	"github.com/abcp-sdk/agent-worker/internal/shellh"
	"github.com/abcp-sdk/agent-worker/internal/webui"
)

func main() {
	addr := flag.String("addr", "", "listen address (default 0.0.0.0:${WORKER_PORT:-8080})")
	workspace := flag.String("workspace", "", "workspace root (default ${WORKER_WORKSPACE} or ~/workspace)")
	dbPath := flag.String("db", "", "job history sqlite path (default ${WORKER_DB} or ./agent-worker.db)")
	flag.Parse()

	listen := *addr
	if listen == "" {
		port := envOr("WORKER_PORT", "8080")
		listen = "0.0.0.0:" + port
	}
	ws := *workspace
	if ws == "" {
		ws = envOr("WORKER_WORKSPACE", defaultWorkspace())
	}
	if err := os.MkdirAll(ws, 0o755); err != nil {
		log.Fatalf("workspace: %v", err)
	}
	db := *dbPath
	if db == "" {
		db = envOr("WORKER_DB", "agent-worker.db")
	}

	// Capture the pre-authorized token, then drop it from the process
	// environment BEFORE building the job env: jobs inherit the worker's
	// environ (see jobEnv), and the token must not travel with them. The auth
	// gate below keeps the returned value in memory.
	bootToken := takeBootToken()

	// Job env: inherit the worker's own environment (the sandbox image is the
	// source of truth for toolchain variables); the token is already gone.
	env := jobEnv()

	runner := shellh.New(ws, env)
	store, err := jobsvc.OpenStore(db)
	if err != nil {
		log.Fatalf("open store %s: %v", db, err)
	}
	jobs := jobsvc.NewManager(runner, store, 10000, 1000)
	files := filesvc.New(ws)
	svc := internal.NewService(jobs, files, runner)

	// Fail-closed auth gate: a token must be supplied at boot (managed
	// sandbox) or claimed once from a startup-minted one-time code (external
	// sandbox / host runner). Enrollment state is persisted (WORKER_STATE_FILE)
	// so an already-claimed worker resumes with the SAME token after a restart
	// — no re-claim. WORKER_REQUIRE_AUTH=0 disables auth (dev only).
	var stateStore auth.StateStore
	if sf := workerStateFile(db); sf != "" {
		stateStore = auth.NewFileStore(sf)
	}
	gate, err := auth.New(auth.Options{
		PreAuthorizedToken: bootToken,
		Disabled:           os.Getenv("WORKER_REQUIRE_AUTH") == "0",
		BootID:             svc.BootID(),
		State:              stateStore,
	})
	if err != nil {
		log.Fatalf("auth: %v", err)
	}
	enroll := internal.NewEnrollService(gate)

	mux := http.NewServeMux()
	// WorkerService is bearer-gated; WorkerEnroll is mounted unprotected (it
	// closes itself after the single successful claim).
	mux.Handle(workerv1connect.NewWorkerServiceHandler(svc,
		connect.WithInterceptors(auth.NewInterceptor(gate))))
	mux.Handle(workerv1connect.NewWorkerEnrollHandler(enroll))
	// Plain health endpoint for probes (Connect has its own but a 200 GET /
	// is the cheapest readiness signal).
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})
	// Built-in static control panel at "/" (same-origin with the RPC above).
	// Registered LAST: the RPC handlers own their longer, more specific paths
	// ("/worker.v1.*"), which the ServeMux prefers over this catch-all.
	mux.Handle("/", webui.Handler())

	// Surface the enrollment state. A RESUMED worker keeps its prior token and
	// is already claimable/usable; an UNCLAIMED worker prints its one-time code
	// (stdout) for a launcher to capture.
	switch {
	case gate.Resumed():
		log.Printf("agent-worker RESUMED — persisted enrollment (no re-claim needed)")
	case gate.Code() != "":
		log.Printf("agent-worker UNCLAIMED — enrollment code: %s", gate.Code())
	}

	// Dual-stack h1 + h2c, mirroring easylab's listener shape so both Connect
	// over h1 (browsers/curl) and h2c-prior-knowledge clients work.
	protocols := new(http.Protocols)
	protocols.SetHTTP1(true)
	protocols.SetUnencryptedHTTP2(true)
	server := &http.Server{
		Addr:      listen,
		Handler:   mux,
		Protocols: protocols,
	}

	ln, err := net.Listen("tcp", listen)
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("agent-worker listening on %s (os=%s arch=%s workspace=%s shell=builtin)",
		listen, runtime.GOOS, runtime.GOARCH, ws)

	// Graceful shutdown on SIGINT/SIGTERM (k8s sends SIGTERM before killing
	// the pod): stop accepting, let in-flight RPCs finish, kill running jobs
	// (their finish records commit) and DRAIN the store writer so the last
	// ≤200ms output batch is not lost.
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		log.Printf("agent-worker shutting down (signal received)")
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if err := server.Shutdown(ctx); err != nil {
			log.Printf("shutdown: %v", err)
		}
		if err := jobs.Close(); err != nil {
			log.Printf("jobs close: %v", err)
		}
		os.Exit(0)
	}()

	log.Fatal(server.Serve(ln))
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// workerStateFile resolves the enrollment state file path. Default: alongside
// the job DB (stable across restarts). WORKER_STATE_FILE overrides it; the
// special value "off" (or empty) disables persistence.
func workerStateFile(dbPath string) string {
	if v, ok := os.LookupEnv("WORKER_STATE_FILE"); ok {
		if v == "" || v == "off" {
			return ""
		}
		return v
	}
	return filepath.Join(filepath.Dir(dbPath), "worker.state")
}

// defaultWorkspace is per-platform: ~/workspace (the worker's own home). The
// deployment may still override it with WORKER_WORKSPACE.
func defaultWorkspace() string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	return filepath.Join(home, "workspace")
}

// takeBootToken reads WORKER_TOKEN and then removes it from the process
// environment, so jobs (which inherit the worker's environ — see jobEnv) can
// never see it. Callers keep the returned value in memory for the auth gate.
func takeBootToken() string {
	tok := os.Getenv("WORKER_TOKEN")
	if tok != "" {
		_ = os.Unsetenv("WORKER_TOKEN")
	}
	return tok
}

// jobEnv builds the base environment for interpreted jobs by INHERITING the
// worker's own environment. The sandbox image (or the host launcher) is the
// source of truth for toolchain variables, so a default-deny allowlist would
// have to enumerate every variable of every toolchain — an endless, brittle
// treadmill that breaks Windows (cmd.exe/ComSpec, MSVC, .NET, Gradle, pip…)
// and any newly added tool. Inheritance means a new toolchain works with no
// code change.
//
// The only secret the worker itself holds (WORKER_TOKEN) is removed from the
// process environment before this runs (takeBootToken), so it is not
// inherited. This is NOT a security boundary — a job runs at the same
// privilege as the worker and could read /proc/<pid>/environ or worker.state
// regardless — it only prevents ACCIDENTAL leakage via `env`/verbose builds.
//
// Per-job ExecuteRequest.env is layered on top by the runner (additive,
// overriding), so callers can still inject arbitrary variables per job.
func jobEnv() []string {
	out := os.Environ()

	// Synthesize platform defaults the process may be missing (e.g. a minimal
	// container with no PATH). Only fills gaps; never overrides.
	if runtime.GOOS == "windows" {
		defaults := [][2]string{
			{"SystemRoot", os.Getenv("SystemRoot")},
			{"SystemDrive", os.Getenv("SystemDrive")},
			{"ComSpec", os.Getenv("ComSpec")},
			{"windir", os.Getenv("windir")},
			{"ProgramData", os.Getenv("ProgramData")},
			{"ProgramFiles", os.Getenv("ProgramFiles")},
			{"ProgramFiles(x86)", os.Getenv("ProgramFiles(x86)")},
			{"LOCALAPPDATA", os.Getenv("LOCALAPPDATA")},
			{"USERPROFILE", os.Getenv("USERPROFILE")},
		}
		for _, kv := range defaults {
			if kv[1] != "" && !containsKey(out, kv[0]) {
				out = append(out, kv[0]+"="+kv[1])
			}
		}
	} else {
		if !containsKey(out, "PATH") {
			out = append(out, "PATH="+defaultUnixPath())
		}
		// CA/trust: preset images bake the egress CA but may not export it; the
		// system bundle path is a safe fallback so TLS clients keep working.
		if !containsKey(out, "SSL_CERT_FILE") {
			if f := firstExistingFile(
				"/etc/ssl/certs/ca-certificates.crt",
				"/etc/ssl/cert.pem",
				"/etc/pki/tls/certs/ca-bundle.crt",
			); f != "" {
				out = append(out, "SSL_CERT_FILE="+f)
			}
		}
	}
	return out
}

// firstExistingFile returns the first path that exists, else "".
func firstExistingFile(paths ...string) string {
	for _, p := range paths {
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

func containsKey(env []string, key string) bool {
	for _, kv := range env {
		if strings.HasPrefix(kv, key+"=") {
			return true
		}
	}
	return false
}

// defaultUnixPath: inside minimal containers PATH may be unset in the worker's
// own environ; give the common toolchain locations.
func defaultUnixPath() string {
	return strings.Join([]string{
		"/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin",
		"/sbin", "/bin", "/root/.cargo/bin", "/root/go/bin",
	}, ":")
}

var _ = connect.NewError // keep import when flag set shrinks
