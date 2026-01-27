package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// TestVerifySignature checks happy-path HMAC validation.
func TestVerifySignature(t *testing.T) {
	secret := []byte("supersecret")
	body := []byte(`{"ref":"refs/heads/master"}`)

	mac := hmac.New(sha256.New, secret)
	mac.Write(body)
	expected := "sha256=" + hex.EncodeToString(mac.Sum(nil))

	if !verifySignature(secret, body, expected) {
		t.Fatalf("expected signature to validate")
	}
}

// failReader fails the test if Read is invoked.
type failReader struct{ t *testing.T }

func (r failReader) Read(_ []byte) (int, error) {
	r.t.Fatalf("request body should not be read")
	return 0, errors.New("read attempted")
}

// TestHandleWebhookTriggersSync ensures push webhook schedules a sync.
func TestHandleWebhookTriggersSync(t *testing.T) {
	secret := []byte("supersecret")
	body := []byte(`{"ref":"refs/heads/master","after":"abc123","repository":{"full_name":"test/repo"},"sender":{"login":"alice"}}`)

	secretPath := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(secretPath, secret, 0o600); err != nil {
		t.Fatalf("write secret: %v", err)
	}

	cfg := Config{
		Port: "0",
		Repos: map[string]*Repo{
			"test/repo": {
				SecretPath:   secretPath,
				Branches:     []string{"master"},
				Command:      []string{"true"},
				WorkingDir:   t.TempDir(),
				QuietMs:      5,
				RunOnStartup: false,
				TimeoutMs:    1000,
			},
		},
	}

	var runs sync.WaitGroup
	runs.Add(1)

	app := &app{
		cfg:      cfg,
		handlers: make(map[string]*repoHandler),
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Initialize handler manually for test.
	handler := &repoHandler{
		fullName: "test/repo",
		repo:     *cfg.Repos["test/repo"],
		secret:   secret,
		timeout:  time.Second,
	}
	handler.deb = newDebouncer(5*time.Millisecond, func(tctx triggerContext) error {
		runs.Done()
		return nil
	})
	go handler.deb.run(ctx)

	app.handlers["test/repo"] = handler

	req := httptest.NewRequest(http.MethodPost, "/webhooks/github", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Event", "push")

	mac := hmac.New(sha256.New, secret)
	mac.Write(body)
	req.Header.Set("X-Hub-Signature-256", "sha256="+hex.EncodeToString(mac.Sum(nil)))

	rr := httptest.NewRecorder()
	app.handleWebhook(rr, req)

	if status := rr.Result().StatusCode; status != http.StatusAccepted {
		t.Fatalf("expected 202, got %d", status)
	}

	done := make(chan struct{})
	go func() {
		runs.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(200 * time.Millisecond):
		t.Fatalf("debounced sync did not run")
	}
}

// TestHandleWebhookPing accepts GitHub ping events after HMAC validation.
func TestHandleWebhookPing(t *testing.T) {
	secret := []byte("supersecret")
	body := []byte(`{"zen":"Keep it logically awesome.","repository":{"full_name":"test/repo"}}`)

	secretPath := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(secretPath, secret, 0o600); err != nil {
		t.Fatalf("write secret: %v", err)
	}

	cfg := Config{
		Port: "0",
		Repos: map[string]*Repo{
			"test/repo": {
				SecretPath: secretPath,
				Branches:   []string{"master"},
				Command:    []string{"true"},
				WorkingDir: t.TempDir(),
			},
		},
	}

	app := &app{
		cfg:      cfg,
		handlers: make(map[string]*repoHandler),
	}

	// Initialize handler.
	handler := &repoHandler{
		fullName: "test/repo",
		repo:     *cfg.Repos["test/repo"],
		secret:   secret,
		timeout:  time.Second,
	}
	app.handlers["test/repo"] = handler

	req := httptest.NewRequest(http.MethodPost, "/webhooks/github",
		bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Event", "ping")

	mac := hmac.New(sha256.New, secret)
	mac.Write(body)
	req.Header.Set("X-Hub-Signature-256",
		"sha256="+hex.EncodeToString(mac.Sum(nil)))

	rr := httptest.NewRecorder()
	app.handleWebhook(rr, req)

	if status := rr.Result().StatusCode; status != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", status)
	}
}

// TestUnsupportedEventShortCircuits ensures we reject before reading body.
func TestUnsupportedEventShortCircuits(t *testing.T) {
	app := &app{
		cfg:      Config{Port: "0"},
		handlers: make(map[string]*repoHandler),
	}

	req := httptest.NewRequest(http.MethodPost, "/webhooks/github", nil)
	req.Body = io.NopCloser(failReader{t: t})
	req.Header.Set("X-GitHub-Event", "issues")

	rr := httptest.NewRecorder()
	app.handleWebhook(rr, req)

	if status := rr.Result().StatusCode; status != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", status)
	}
}

// TestHandleWebhookWrongBranch rejects non-target branches.
func TestHandleWebhookWrongBranch(t *testing.T) {
	secret := []byte("supersecret")
	body := []byte(`{"ref":"refs/heads/feature","repository":{"full_name":"test/repo"},"sender":{"login":"alice"}}`)

	secretPath := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(secretPath, secret, 0o600); err != nil {
		t.Fatalf("write secret: %v", err)
	}

	cfg := Config{
		Port: "0",
		Repos: map[string]*Repo{
			"test/repo": {
				SecretPath: secretPath,
				Branches:   []string{"master"},
				Command:    []string{"true"},
				WorkingDir: t.TempDir(),
			},
		},
	}

	app := &app{
		cfg:      cfg,
		handlers: make(map[string]*repoHandler),
	}

	handler := &repoHandler{
		fullName: "test/repo",
		repo:     *cfg.Repos["test/repo"],
		secret:   secret,
		timeout:  time.Second,
	}
	app.handlers["test/repo"] = handler

	req := httptest.NewRequest(http.MethodPost, "/webhooks/github", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Event", "push")
	mac := hmac.New(sha256.New, secret)
	mac.Write(body)
	req.Header.Set("X-Hub-Signature-256", "sha256="+hex.EncodeToString(mac.Sum(nil)))

	rr := httptest.NewRecorder()
	app.handleWebhook(rr, req)

	if status := rr.Result().StatusCode; status != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", status)
	}
}

// TestIntegrationFetchReset spins up a temp git remote/working tree and ensures
// a push webhook clears local dirty state via fetch+reset.
func TestIntegrationFetchReset(t *testing.T) {
	base := t.TempDir()
	remote := filepath.Join(base, "remote.git")
	work := filepath.Join(base, "work")

	run := func(args ...string) {
		cmd := exec.Command(args[0], args[1:]...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("cmd %v failed: %v\n%s", args, err, out)
		}
	}

	run("git", "init", "--bare", remote)
	run("git", "clone", "--origin", "upstream", remote, work)
	run("git", "-C", work, "config", "user.email", "test@example.com")
	run("git", "-C", work, "config", "user.name", "tester")
	run("git", "-C", work, "config", "commit.gpgsign", "false")

	readme := filepath.Join(work, "README.md")
	if err := os.WriteFile(readme, []byte("from-remote\n"), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}
	run("git", "-C", work, "add", "README.md")
	run("git", "-C", work, "commit", "-m", "init")
	run("git", "-C", work, "push", "upstream", "master:master")

	secret := []byte("supersecret")
	secretPath := filepath.Join(base, "secret")
	if err := os.WriteFile(secretPath, secret, 0o600); err != nil {
		t.Fatalf("secret write: %v", err)
	}

	// Create JSON config file.
	cfg := Config{
		Port: "0",
		Repos: map[string]*Repo{
			"test/repo": {
				SecretPath:   secretPath,
				Branches:     []string{"master"},
				Command:      []string{"bash", "-c", "git fetch upstream && git reset --hard upstream/master"},
				WorkingDir:   work,
				QuietMs:      20,
				RunOnStartup: true,
				TimeoutMs:    5000,
			},
		},
	}

	app := &app{
		cfg:      cfg,
		handlers: make(map[string]*repoHandler),
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Initialize handler using actual runCommand.
	handler := &repoHandler{
		fullName: "test/repo",
		repo:     *cfg.Repos["test/repo"],
		secret:   secret,
		timeout:  5 * time.Second,
	}

	doneRun := make(chan struct{}, 1)
	handler.deb = newDebouncer(20*time.Millisecond, func(tctx triggerContext) error {
		defer func() {
			select {
			case doneRun <- struct{}{}:
			default:
			}
		}()
		return handler.runCommand(ctx, tctx)
	})
	go handler.deb.run(ctx)
	app.handlers["test/repo"] = handler

	// Run startup command.
	if err := handler.runCommand(ctx, triggerContext{event: "startup"}); err != nil {
		t.Fatalf("startup command: %v", err)
	}

	// Introduce local dirty change after initial sync.
	if err := os.WriteFile(readme, []byte("local-dirty\n"), 0o644); err != nil {
		t.Fatalf("dirty write: %v", err)
	}

	body := []byte(`{"ref":"refs/heads/master","after":"abc123","repository":{"full_name":"test/repo"},"sender":{"login":"alice"}}`)
	mac := hmac.New(sha256.New, secret)
	mac.Write(body)
	sig := "sha256=" + hex.EncodeToString(mac.Sum(nil))

	req := httptest.NewRequest(http.MethodPost, "/webhooks/github", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Event", "push")
	req.Header.Set("X-Hub-Signature-256", sig)

	// drain startup run notification
	select {
	case <-doneRun:
	default:
	}

	rr := httptest.NewRecorder()
	app.handleWebhook(rr, req)

	if rr.Result().StatusCode != http.StatusAccepted {
		t.Fatalf("expected 202, got %d", rr.Result().StatusCode)
	}

	select {
	case <-doneRun:
	case <-time.After(2 * time.Second):
		t.Fatalf("sync did not run")
	}

	data, err := os.ReadFile(readme)
	if err != nil {
		t.Fatalf("read back file: %v", err)
	}
	if string(data) != "from-remote\n" {
		t.Fatalf("expected file reset to remote, got %q", data)
	}
}

// TestConfigLoading verifies JSON config parsing.
func TestConfigLoading(t *testing.T) {
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.json")

	configData := `{
		"port": "8080",
		"repos": {
			"owner/repo": {
				"secret_path": "/tmp/secret",
				"branches": ["main", "dev"],
				"command": ["echo", "hello"],
				"working_dir": "/tmp/work",
				"quiet_ms": 1000,
				"run_on_startup": true,
				"timeout_ms": 60000
			}
		}
	}`

	if err := os.WriteFile(configPath, []byte(configData), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	cfg, err := loadConfig(configPath)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}

	if cfg.Port != "8080" {
		t.Errorf("expected port 8080, got %s", cfg.Port)
	}

	if len(cfg.Repos) != 1 {
		t.Fatalf("expected 1 repo, got %d", len(cfg.Repos))
	}

	repo, ok := cfg.Repos["owner/repo"]
	if !ok {
		t.Fatal("expected repo with key owner/repo")
	}

	if len(repo.Branches) != 2 {
		t.Errorf("expected 2 branches, got %d", len(repo.Branches))
	}

	if !repo.RunOnStartup {
		t.Error("expected runOnStartup to be true")
	}
}

// TestMultiRepoRouting verifies that webhooks route to the correct repo handler.
func TestMultiRepoRouting(t *testing.T) {
	secret := []byte("supersecret")
	secretPath := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(secretPath, secret, 0o600); err != nil {
		t.Fatalf("write secret: %v", err)
	}

	cfg := Config{
		Port: "0",
		Repos: map[string]*Repo{
			"owner/repo1": {
				SecretPath: secretPath,
				Branches:   []string{"main"},
				Command:    []string{"echo", "repo1"},
				WorkingDir: t.TempDir(),
			},
			"owner/repo2": {
				SecretPath: secretPath,
				Branches:   []string{"master"},
				Command:    []string{"echo", "repo2"},
				WorkingDir: t.TempDir(),
			},
		},
	}

	app := &app{
		cfg:      cfg,
		handlers: make(map[string]*repoHandler),
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var repo1Runs, repo2Runs int
	var mu sync.Mutex

	// Setup repo1 handler.
	handler1 := &repoHandler{
		fullName: "owner/repo1",
		repo:     *cfg.Repos["owner/repo1"],
		secret:   secret,
		timeout:  time.Second,
	}
	handler1.deb = newDebouncer(5*time.Millisecond, func(tctx triggerContext) error {
		mu.Lock()
		repo1Runs++
		mu.Unlock()
		return nil
	})
	go handler1.deb.run(ctx)
	app.handlers["owner/repo1"] = handler1

	// Setup repo2 handler.
	handler2 := &repoHandler{
		fullName: "owner/repo2",
		repo:     *cfg.Repos["owner/repo2"],
		secret:   secret,
		timeout:  time.Second,
	}
	handler2.deb = newDebouncer(5*time.Millisecond, func(tctx triggerContext) error {
		mu.Lock()
		repo2Runs++
		mu.Unlock()
		return nil
	})
	go handler2.deb.run(ctx)
	app.handlers["owner/repo2"] = handler2

	// Send webhook for repo1.
	body1 := []byte(`{"ref":"refs/heads/main","repository":{"full_name":"owner/repo1"},"sender":{"login":"alice"}}`)
	mac1 := hmac.New(sha256.New, secret)
	mac1.Write(body1)

	req1 := httptest.NewRequest(http.MethodPost, "/webhooks/github", bytes.NewReader(body1))
	req1.Header.Set("X-GitHub-Event", "push")
	req1.Header.Set("X-Hub-Signature-256", "sha256="+hex.EncodeToString(mac1.Sum(nil)))

	rr1 := httptest.NewRecorder()
	app.handleWebhook(rr1, req1)

	if rr1.Code != http.StatusAccepted {
		t.Fatalf("expected 202 for repo1, got %d", rr1.Code)
	}

	// Send webhook for repo2.
	body2 := []byte(`{"ref":"refs/heads/master","repository":{"full_name":"owner/repo2"},"sender":{"login":"bob"}}`)
	mac2 := hmac.New(sha256.New, secret)
	mac2.Write(body2)

	req2 := httptest.NewRequest(http.MethodPost, "/webhooks/github", bytes.NewReader(body2))
	req2.Header.Set("X-GitHub-Event", "push")
	req2.Header.Set("X-Hub-Signature-256", "sha256="+hex.EncodeToString(mac2.Sum(nil)))

	rr2 := httptest.NewRecorder()
	app.handleWebhook(rr2, req2)

	if rr2.Code != http.StatusAccepted {
		t.Fatalf("expected 202 for repo2, got %d", rr2.Code)
	}

	// Wait for debounced executions.
	time.Sleep(100 * time.Millisecond)

	mu.Lock()
	defer mu.Unlock()

	if repo1Runs != 1 {
		t.Errorf("expected repo1 to run once, got %d", repo1Runs)
	}

	if repo2Runs != 1 {
		t.Errorf("expected repo2 to run once, got %d", repo2Runs)
	}
}
