// `github-webhook` is a GitHub webhook listener that routes push events to
// configured repository handlers which execute arbitrary commands.
//
// design:
//
//   - single HTTP endpoint for all webhooks: POST /webhooks/github
//   - JSON-based configuration loaded at startup
//   - per-repo HMAC verification (each repo can have different secret)
//   - per-repo command execution with standard environment variables
//   - per-repo debouncing to avoid overlapping commands (serial execution)
//   - optional run-on-startup for initial sync
//   - generous 1-hour command timeout
//   - logs to stderr for journald
//
// config file structure (JSON):
//
//	{
//	  "port": "8673",
//	  "repos": {
//	    "phlip9/dotfiles": {
//	      "secret_path": "/run/credentials/github-webhook/dotfiles-secret",
//	      "branches": ["master"],
//	      "command": ["/path/to/script.sh"],
//	      "working_dir": "/home/phlip9/dev/dotfiles",
//	      "quiet_ms": 500,
//	      "run_on_startup": true,
//	      "timeout_ms": 3600000
//	    }
//	  }
//	}
//
// environment variables passed to commands:
//
//   - GH_EVENT: event type (e.g., "push", "ping")
//   - GH_REPO: repository full name (e.g., "phlip9/dotfiles")
//   - GH_REF: git ref (e.g., "refs/heads/master")
//   - GH_BRANCH: branch name (e.g., "master")
//   - GH_COMMIT: commit SHA
//   - GH_SENDER: GitHub username who triggered the event
//
// envs:
//
// - CONFIG_PATH: path to JSON configuration file
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
	"strings"
	"time"
)

// Config is the top-level configuration structure.
type Config struct {
	Port  string           `json:"port"`
	Repos map[string]*Repo `json:"repos"`
}

// Repo represents a repository configuration.
type Repo struct {
	SecretPath   string   `json:"secret_path"`
	Branches     []string `json:"branches"`
	Command      []string `json:"command"`
	WorkingDir   string   `json:"working_dir"`
	QuietMs      int      `json:"quiet_ms"`
	RunOnStartup bool     `json:"run_on_startup"`
	TimeoutMs    int      `json:"timeout_ms"`
}

// app holds the HTTP server and repository handlers.
type app struct {
	cfg      Config
	handlers map[string]*repoHandler // key: repo full_name
}

// repoHandler manages command execution for a single repository.
type repoHandler struct {
	fullName string
	repo     Repo
	secret   []byte
	deb      *debouncer
	timeout  time.Duration
}

// pushEvent models GitHub push webhook payload (minimal fields).
type pushEvent struct {
	Ref        string `json:"ref"`
	After      string `json:"after"`
	Repository struct {
		FullName string `json:"full_name"`
	} `json:"repository"`
	Sender struct {
		Login string `json:"login"`
	} `json:"sender"`
}

// pingEvent models GitHub ping webhook payload (minimal fields).
type pingEvent struct {
	Repository struct {
		FullName string `json:"full_name"`
	} `json:"repository"`
}

// main loads config, initializes handlers, runs startup commands, starts server.
func main() {
	log.SetFlags(0)

	configPath := os.Getenv("CONFIG_PATH")
	if configPath == "" {
		log.Fatal("CONFIG_PATH is required")
	}

	cfg, err := loadConfig(configPath)
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	a := &app{
		cfg:      cfg,
		handlers: make(map[string]*repoHandler),
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Initialize handlers for each repo.
	for repoFullName, repo := range cfg.Repos {
		secret, err := readSecret(repo.SecretPath)
		if err != nil {
			log.Fatalf("read secret for repo %s: %v", repoFullName, err)
		}

		timeout := time.Duration(repo.TimeoutMs) * time.Millisecond
		quiet := time.Duration(repo.QuietMs) * time.Millisecond

		handler := &repoHandler{
			fullName: repoFullName,
			repo:     *repo,
			secret:   secret,
			timeout:  timeout,
		}

		handler.deb = newDebouncer(quiet, func(tctx triggerContext) error {
			return handler.runCommand(ctx, tctx)
		})

		a.handlers[repoFullName] = handler

		// Start debouncer goroutine.
		go handler.deb.run(ctx)

		// Run startup command if configured.
		if repo.RunOnStartup {
			log.Printf("[%s] running startup command", repoFullName)
			tctx := triggerContext{event: "startup"}
			if err := handler.runCommand(ctx, tctx); err != nil {
				log.Printf("[%s] startup command failed: %v", repoFullName, err)
			}
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/webhooks/github", a.handleWebhook)
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

// loadConfig reads and parses the JSON configuration file.
func loadConfig(path string) (Config, error) {
	var cfg Config

	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, fmt.Errorf("read file: %w", err)
	}

	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, fmt.Errorf("parse json: %w", err)
	}

	return cfg, nil
}

// readSecret loads and trims a secret file.
func readSecret(path string) ([]byte, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return bytes.TrimSpace(raw), nil
}

// handleWebhook routes GitHub webhooks to appropriate repo handlers.
func (a *app) handleWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	event := r.Header.Get("X-GitHub-Event")
	switch event {
	case "":
		http.Error(w, "missing X-GitHub-Event", http.StatusBadRequest)
		return
	case "push", "ping":
	default:
		http.Error(w, "unsupported event", http.StatusBadRequest)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		http.Error(w, "read body", http.StatusBadRequest)
		return
	}

	// Parse payload to extract repository name (works for both push and ping).
	var repoPayload struct {
		Repository struct {
			FullName string `json:"full_name"`
		} `json:"repository"`
	}
	if err := json.Unmarshal(body, &repoPayload); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}

	handler, exists := a.handlers[repoPayload.Repository.FullName]
	if !exists {
		http.Error(w, "repository not configured", http.StatusNotFound)
		return
	}

	// Verify signature with this repo's handler secret.
	sigHeader := r.Header.Get("X-Hub-Signature-256")
	if !verifySignature(handler.secret, body, sigHeader) {
		http.Error(w, "invalid signature", http.StatusUnauthorized)
		return
	}

	// Handle ping events (no further processing needed).
	if event == "ping" {
		w.WriteHeader(http.StatusNoContent)
		return
	}

	// Handle push events.
	var payload pushEvent
	if err := json.Unmarshal(body, &payload); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}

	// Extract branch from ref.
	branch := strings.TrimPrefix(payload.Ref, "refs/heads/")

	// Check if branch is in allowed list.
	allowed := false
	for _, b := range handler.repo.Branches {
		if b == branch {
			allowed = true
			break
		}
	}
	if !allowed {
		http.Error(w, "branch not tracked", http.StatusBadRequest)
		return
	}

	// Trigger debounced command execution.
	handler.deb.triggerWithContext(event, payload.Ref, branch, payload.After, payload.Sender.Login)
	w.WriteHeader(http.StatusAccepted)
}

// handleHealth answers liveness probes.
func handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, "ok\n")
}

// runCommand executes the configured command with GitHub event context.
func (h *repoHandler) runCommand(ctx context.Context, tctx triggerContext) error {
	if len(h.repo.Command) == 0 {
		return errors.New("no command configured")
	}

	cmdCtx, cancel := context.WithTimeout(ctx, h.timeout)
	defer cancel()

	cmd := exec.CommandContext(cmdCtx, h.repo.Command[0], h.repo.Command[1:]...)
	cmd.Dir = h.repo.WorkingDir

	// Set environment variables with GitHub event context.
	cmd.Env = append(os.Environ(),
		"GH_EVENT="+tctx.event,
		"GH_REPO="+h.fullName,
		"GH_REF="+tctx.ref,
		"GH_BRANCH="+tctx.branch,
		"GH_COMMIT="+tctx.commit,
		"GH_SENDER="+tctx.sender,
	)

	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf

	err := cmd.Run()
	log.Printf("[%s] cmd: %s\n%s",
		h.fullName,
		strings.Join(h.repo.Command, " "),
		buf.String())

	if err != nil {
		return fmt.Errorf("command failed: %w", err)
	}

	return nil
}

// debouncer coalesces rapid triggers and runs a single worker call.
type debouncer struct {
	quiet     time.Duration
	triggerCh chan triggerContext
	runFn     func(triggerContext) error
}

// triggerContext carries webhook context for debounced execution.
type triggerContext struct {
	event  string
	ref    string
	branch string
	commit string
	sender string
}

// newDebouncer constructs a debouncer with buffered trigger channel.
func newDebouncer(quiet time.Duration, runFn func(triggerContext) error) *debouncer {
	return &debouncer{
		quiet:     quiet,
		triggerCh: make(chan triggerContext, 1),
		runFn:     runFn,
	}
}

// trigger requests a run with minimal context (for startup).
func (d *debouncer) trigger() {
	d.triggerWithContext("", "", "", "", "")
}

// triggerWithContext requests a run with full webhook context.
func (d *debouncer) triggerWithContext(event, ref, branch, commit, sender string) {
	ctx := triggerContext{
		event:  event,
		ref:    ref,
		branch: branch,
		commit: commit,
		sender: sender,
	}
	select {
	case d.triggerCh <- ctx:
	default:
	}
}

// run listens for triggers, waits for quiet period, then executes runFn.
func (d *debouncer) run(ctx context.Context) {
	var timer *time.Timer
	var timerC <-chan time.Time
	var pending *triggerContext

	for {
		select {
		case <-ctx.Done():
			if timer != nil {
				timer.Stop()
			}
			return
		case tctx := <-d.triggerCh:
			pending = &tctx
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
			if pending == nil {
				continue
			}

			// Capture context and clear pending.
			tctx := *pending
			pending = nil

			// Run worker; failures are logged but do not stop loop.
			if err := d.runFn(tctx); err != nil {
				log.Printf("command failed: %v", err)
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
