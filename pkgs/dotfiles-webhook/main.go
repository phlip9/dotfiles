// `dotfiles-webhook` is a tiny GitHub webhook listener used on `omnara1` to
// keep `/home/phlip9/dev/dotfiles` set to `upstream/master` within seconds of
// a push.
//
// design constraints:
//
//   - just need to react to push events for one branch
//   - verify GitHub's sha256 HMAC using a secret injected via systemd
//     LoadCredential
//   - avoid overlapping git resets
//     To meet that, we gate all runs through a single debounced worker
//     (quiet window default 500ms)
//   - run an initial fetch+reset loop with capped backoff before serving so even
//     if we miss notifications during downtime, we'll still get up-to-date after
//     we restart.
//   - logs go to stderr for journald
//   - all git commands run in the existing checkout (reuse configured remote URL,
//     ssh agent, etc.).
//   - there is no IP allowlist; nginx and the shared secret provide the only
//     ingress control.
//
// envs:
//
// - PORT: listen port (default 8673)
// - REPO: git working tree path (default /home/phlip9/dev/dotfiles)
// - REMOTE: git remote name to fetch/reset (default upstream)
// - BRANCH: branch name to track (default master)
// - QUIET_MS: debounce quiet period in milliseconds (default 500)
// - MAX_BACKOFF: max initial-sync backoff in milliseconds (default 30000)
// - GITHUB_WEBHOOK_SECRET_PATH: required path to shared secret file
package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// config holds runtime options parsed from the environment.
type config struct {
	Port       string
	Repo       string
	Remote     string
	Branch     string
	Quiet      time.Duration
	MaxBackoff time.Duration
	SecretPath string
}

// app is the HTTP server plus sync worker state.
type app struct {
	cfg    config
	secret []byte
	deb    *debouncer
	run    func(context.Context) error
}

// pushEvent models the minimal fields we care about from a GitHub push.
type pushEvent struct {
	Ref string `json:"ref"`
}

// main wires config, secret, initial sync, debouncer, and HTTP server.
func main() {
	// journald provides timestamps; keep logs message-only.
	log.SetFlags(0)

	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	secret, err := readSecret(cfg.SecretPath)
	if err != nil {
		log.Fatalf("secret: %v", err)
	}

	a := &app{
		cfg:    cfg,
		secret: secret,
		run:    nil, // filled in below
	}
	// default run implementation points to git-backed sync.
	a.run = a.runSync

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Block until first successful fetch/reset so we never serve stale repo.
	if err := a.initialSync(ctx); err != nil {
		log.Fatalf("initial sync: %v", err)
	}

	// Debounced worker for subsequent webhook-triggered syncs.
	a.deb = newDebouncer(cfg.Quiet, func() error { return a.run(ctx) })

	go a.deb.run(ctx)

	mux := http.NewServeMux()
	mux.HandleFunc("/webhooks/dotfiles", a.handleWebhook)
	mux.HandleFunc("/healthz", handleHealth)

	addr := ":" + cfg.Port
	server := &http.Server{
		Addr:    addr,
		Handler: mux,
	}

	log.Printf("listening on %s", addr)

	if err := server.ListenAndServe(); err != nil &&
		!errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("http server: %v", err)
	}
}

// loadConfig reads env vars and applies defaults.
func loadConfig() (config, error) {
	var cfg config

	cfg.Port = getenvDefault("PORT", "8673")
	cfg.Repo = getenvDefault("REPO", "/home/phlip9/dev/dotfiles")
	cfg.Remote = getenvDefault("REMOTE", "upstream")
	cfg.Branch = getenvDefault("BRANCH", "master")

	quietMs, err := getenvInt("QUIET_MS", 500)
	if err != nil {
		return cfg, fmt.Errorf("invalid QUIET_MS: %w", err)
	}
	cfg.Quiet = time.Duration(quietMs) * time.Millisecond

	maxBackoffMs, err := getenvInt("MAX_BACKOFF", 30000)
	if err != nil {
		return cfg, fmt.Errorf("invalid MAX_BACKOFF: %w", err)
	}
	cfg.MaxBackoff = time.Duration(maxBackoffMs) * time.Millisecond

	cfg.SecretPath = os.Getenv("GITHUB_WEBHOOK_SECRET_PATH")
	if cfg.SecretPath == "" {
		return cfg, errors.New("GITHUB_WEBHOOK_SECRET_PATH is required")
	}

	return cfg, nil
}

// getenvDefault returns env value or default if unset.
func getenvDefault(key, def string) string {
	val := os.Getenv(key)
	if val != "" {
		return val
	}
	return def
}

// getenvInt parses an int env var or returns provided default.
func getenvInt(key string, def int) (int, error) {
	val := os.Getenv(key)
	if val == "" {
		return def, nil
	}
	n, err := strconv.Atoi(val)
	if err != nil {
		return 0, err
	}
	return n, nil
}

// readSecret loads and trims the webhook secret file.
func readSecret(path string) ([]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return bytes.TrimSpace(raw), nil
}

// handleWebhook validates headers, HMAC, branch, then triggers debounce.
func (a *app) handleWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	if event := r.Header.Get("X-GitHub-Event"); event != "push" {
		http.Error(w, "unsupported event", http.StatusBadRequest)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}

	sigHeader := r.Header.Get("X-Hub-Signature-256")
	if !verifySignature(a.secret, body, sigHeader) {
		http.Error(w, "invalid signature", http.StatusUnauthorized)
		return
	}

	var event pushEvent
	if err := json.Unmarshal(body, &event); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}

	expectedRef := "refs/heads/" + a.cfg.Branch
	if event.Ref != expectedRef {
		http.Error(w, "unexpected ref", http.StatusBadRequest)
		return
	}

	a.deb.trigger()
	w.WriteHeader(http.StatusAccepted)
}

// handleHealth answers simple liveness probes.
func handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, "ok\n")
}

// initialSync retries fetch+reset with exponential backoff until success.
func (a *app) initialSync(ctx context.Context) error {
	backoff := time.Second
	for {
		if err := a.run(ctx); err == nil {
			return nil
		} else {
			log.Printf("initial sync failed: %v; retrying in %s",
				err, backoff)
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(backoff):
		}

		backoff *= 2
		if backoff > a.cfg.MaxBackoff {
			backoff = a.cfg.MaxBackoff
		}
	}
}

// runSync executes the git fetch + hard reset sequence.
func (a *app) runSync(ctx context.Context) error {
	cmds := [][]string{
		{"git", "-C", a.cfg.Repo, "fetch", a.cfg.Remote},
		{
			"git",
			"-C",
			a.cfg.Repo,
			"reset",
			"--hard",
			fmt.Sprintf("%s/%s", a.cfg.Remote, a.cfg.Branch),
		},
	}

	for _, args := range cmds {
		cmd := exec.CommandContext(ctx, args[0], args[1:]...)
		var buf bytes.Buffer
		cmd.Stdout = &buf
		cmd.Stderr = &buf

		err := cmd.Run()
		log.Printf("cmd: %s\n%s", strings.Join(args, " "), buf.String())
		if err != nil {
			return fmt.Errorf("command failed: %w", err)
		}
	}

	return nil
}

// debouncer coalesces rapid triggers and runs a single worker call.
type debouncer struct {
	quiet     time.Duration
	triggerCh chan struct{}
	runFn     func() error
}

// newDebouncer constructs a debouncer with buffered trigger channel.
func newDebouncer(quiet time.Duration, runFn func() error) *debouncer {
	return &debouncer{
		quiet:     quiet,
		triggerCh: make(chan struct{}, 1),
		runFn:     runFn,
	}
}

// trigger requests a run, dropping if one is already pending.
func (d *debouncer) trigger() {
	select {
	case d.triggerCh <- struct{}{}:
	default:
	}
}

// run listens for triggers, waits for quiet period, then executes runFn.
func (d *debouncer) run(ctx context.Context) {
	var timer *time.Timer
	var timerC <-chan time.Time
	pending := false

	for {
		select {
		case <-ctx.Done():
			if timer != nil {
				timer.Stop()
			}
			return
		case <-d.triggerCh:
			pending = true
			// Restart quiet timer on every trigger to coalesce bursts.
			if timer != nil {
				if !timer.Stop() {
					<-timer.C
				}
			}
			timer = time.NewTimer(d.quiet)
			timerC = timer.C
		case <-timerC:
			timerC = nil
			if timer != nil {
				timer.Stop()
				timer = nil
			}
			if !pending {
				continue
			}
			pending = false
			// Run worker; failures are logged but do not stop loop.
			if err := d.runFn(); err != nil {
				log.Printf("sync failed: %v", err)
			}
		}
	}
}

// verifySignature checks GitHub X-Hub-Signature-256 against body.
func verifySignature(secret, body []byte, header string) bool {
	if !strings.HasPrefix(header, "sha256=") {
		return false
	}
	hexSig := strings.TrimPrefix(header, "sha256=")
	sig, err := hex.DecodeString(hexSig)
	if err != nil {
		return false
	}

	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write(body)
	expected := mac.Sum(nil)

	return hmac.Equal(expected, sig)
}
