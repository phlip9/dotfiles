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
	body := []byte(`{"ref":"refs/heads/master"}`)

	cfg := config{
		Port:       "0",
		Repo:       "/tmp/irrelevant",
		Remote:     "upstream",
		Branch:     "master",
		Quiet:      5 * time.Millisecond,
		MaxBackoff: 50 * time.Millisecond,
		SecretPath: "/dev/null",
	}

	var runs sync.WaitGroup
	runs.Add(1)

	app := &app{
		cfg:    cfg,
		secret: secret,
		run: func(context.Context) error {
			runs.Done()
			return nil
		},
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	app.deb = newDebouncer(cfg.Quiet, func() error { return app.run(ctx) })
	go app.deb.run(ctx)

	req := httptest.NewRequest(http.MethodPost, "/webhooks/dotfiles", bytes.NewReader(body))
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
	body := []byte(`{"zen":"Keep it logically awesome."}`)

	cfg := config{
		Port:       "0",
		Repo:       "/tmp/irrelevant",
		Remote:     "upstream",
		Branch:     "master",
		Quiet:      5 * time.Millisecond,
		MaxBackoff: 50 * time.Millisecond,
		SecretPath: "/dev/null",
	}

	app := &app{
		cfg:    cfg,
		secret: secret,
		run:    func(context.Context) error { return nil },
	}

	req := httptest.NewRequest(http.MethodPost, "/webhooks/dotfiles",
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
	cfg := config{
		Port:       "0",
		Repo:       "/tmp/irrelevant",
		Remote:     "upstream",
		Branch:     "master",
		Quiet:      5 * time.Millisecond,
		MaxBackoff: 50 * time.Millisecond,
		SecretPath: "/dev/null",
	}

	app := &app{
		cfg:    cfg,
		secret: []byte("irrelevant"),
		run:    func(context.Context) error { return nil },
	}

	req := httptest.NewRequest(http.MethodPost, "/webhooks/dotfiles", nil)
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
	body := []byte(`{"ref":"refs/heads/feature"}`)

	cfg := config{
		Port:       "0",
		Repo:       "/tmp/irrelevant",
		Remote:     "upstream",
		Branch:     "master",
		Quiet:      5 * time.Millisecond,
		MaxBackoff: 50 * time.Millisecond,
		SecretPath: "/dev/null",
	}

	app := &app{
		cfg:    cfg,
		secret: secret,
		run:    func(context.Context) error { return nil },
	}

	req := httptest.NewRequest(http.MethodPost, "/webhooks/dotfiles", bytes.NewReader(body))
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

	cfg := config{
		Port:       "0",
		Repo:       work,
		Remote:     "upstream",
		Branch:     "master",
		Quiet:      20 * time.Millisecond,
		MaxBackoff: 100 * time.Millisecond,
		SecretPath: secretPath,
	}

	app := &app{
		cfg:    cfg,
		secret: secret,
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	doneRun := make(chan struct{}, 1)
	app.run = func(ctx context.Context) error {
		defer func() {
			select {
			case doneRun <- struct{}{}:
			default:
			}
		}()
		return app.runSync(ctx)
	}

	app.deb = newDebouncer(cfg.Quiet, func() error { return app.run(ctx) })

	if err := app.initialSync(ctx); err != nil {
		t.Fatalf("initial sync: %v", err)
	}

	// Introduce local dirty change after initial sync so webhook must fix it.
	if err := os.WriteFile(readme, []byte("local-dirty\n"), 0o644); err != nil {
		t.Fatalf("dirty write: %v", err)
	}

	go app.deb.run(ctx)

	body := []byte(`{"ref":"refs/heads/master"}`)
	mac := hmac.New(sha256.New, secret)
	mac.Write(body)
	sig := "sha256=" + hex.EncodeToString(mac.Sum(nil))

	req := httptest.NewRequest(http.MethodPost, "/webhooks/dotfiles", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-GitHub-Event", "push")
	req.Header.Set("X-Hub-Signature-256", sig)

	// drain initialSync run notification
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
