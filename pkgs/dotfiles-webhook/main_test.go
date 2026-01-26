package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
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
