package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeShutdownServer struct {
	shutdownCalls chan struct{}
}

func (server *fakeShutdownServer) Shutdown(_ context.Context) error {
	server.shutdownCalls <- struct{}{}
	return nil
}

// TestIdleShutdownMonitorStopsServer verifies idle self-shutdown behavior.
func TestIdleShutdownMonitorStopsServer(t *testing.T) {
	fakeAPI := newFakeGitHubAPI()
	broker := newTestBroker(t, fakeAPI)
	apiServer := newAPIServer(broker, 100*time.Millisecond)
	shutdownServer := &fakeShutdownServer{
		shutdownCalls: make(chan struct{}, 1),
	}

	apiServer.startIdleShutdownMonitor(shutdownServer)

	select {
	case <-shutdownServer.shutdownCalls:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for idle shutdown")
	}
}

// TestExpandCredentialPath verifies %d/ expansion via credentials directory.
func TestExpandCredentialPath(t *testing.T) {
	t.Setenv("CREDENTIALS_DIRECTORY", "/run/credentials/test-unit")

	got, err := expandCredentialPath("%d/app-key")
	if err != nil {
		t.Fatalf("expandCredentialPath: %v", err)
	}

	want := "/run/credentials/test-unit/app-key"
	if got != want {
		t.Fatalf("expected %q, got %q", want, got)
	}
}

// TestReadPrivateKey verifies PEM key parsing for generated test keys.
func TestReadPrivateKey(t *testing.T) {
	privateKeyPath := writeRSAPrivateKeyPEM(t)
	_, err := readPrivateKey(privateKeyPath)
	if err != nil {
		t.Fatalf("readPrivateKey: %v", err)
	}
}

// TestTokenForRepoCachesInstallationAndToken verifies positive cache hits.
func TestTokenForRepoCachesInstallationAndToken(t *testing.T) {
	fakeAPI := newFakeGitHubAPI()
	broker := newTestBroker(t, fakeAPI)

	first, err := broker.tokenForRepo(context.Background(), "test", "repo")
	if err != nil {
		t.Fatalf("first tokenForRepo failed: %v", err)
	}

	second, err := broker.tokenForRepo(context.Background(), "test", "repo")
	if err != nil {
		t.Fatalf("second tokenForRepo failed: %v", err)
	}

	if first.Token != second.Token {
		t.Fatalf("expected cached token, got %q then %q", first.Token, second.Token)
	}

	if got := fakeAPI.installationCallsFor("test/repo"); got != 1 {
		t.Fatalf("expected 1 installation lookup, got %d", got)
	}

	if got := fakeAPI.tokenCallsFor(101); got != 1 {
		t.Fatalf("expected 1 token mint call, got %d", got)
	}
}

// TestTokenForRepoNegativeInstallationCache verifies negative cache hits.
func TestTokenForRepoNegativeInstallationCache(t *testing.T) {
	fakeAPI := newFakeGitHubAPI()
	broker := newTestBroker(t, fakeAPI)

	_, firstErr := broker.tokenForRepo(context.Background(), "test", "missing")
	if !isErrorKind(firstErr, errorKindUnknownInstallation) {
		t.Fatalf("expected unknown installation error, got %v", firstErr)
	}

	_, secondErr := broker.tokenForRepo(context.Background(), "test", "missing")
	if !isErrorKind(secondErr, errorKindUnknownInstallation) {
		t.Fatalf("expected unknown installation error, got %v", secondErr)
	}

	if got := fakeAPI.installationCallsFor("test/missing"); got != 1 {
		t.Fatalf("expected 1 installation lookup, got %d", got)
	}
}

// TestTokenForRepoRetriesAfterStaleInstallation verifies stale-id recovery.
func TestTokenForRepoRetriesAfterStaleInstallation(t *testing.T) {
	fakeAPI := newFakeGitHubAPI()
	broker := newTestBroker(t, fakeAPI)

	token, err := broker.tokenForRepo(context.Background(), "test", "stale")
	if err != nil {
		t.Fatalf("tokenForRepo failed: %v", err)
	}

	if token.Token != "stale-token-1" {
		t.Fatalf("unexpected token %q", token.Token)
	}

	if got := fakeAPI.installationCallsFor("test/stale"); got != 2 {
		t.Fatalf("expected 2 installation lookups, got %d", got)
	}

	if got := fakeAPI.tokenCallsFor(200); got != 1 {
		t.Fatalf("expected 1 stale token call, got %d", got)
	}

	if got := fakeAPI.tokenCallsFor(201); got != 1 {
		t.Fatalf("expected 1 fresh token call, got %d", got)
	}
}

// TestHandleRepoTokenEndpoint verifies success endpoint behavior.
func TestHandleRepoTokenEndpoint(t *testing.T) {
	fakeAPI := newFakeGitHubAPI()

	server := &apiServer{
		broker: newTestBroker(t, fakeAPI),
	}

	request := httptest.NewRequest(
		http.MethodGet,
		"/repos/test/repo/token",
		nil,
	)
	response := httptest.NewRecorder()
	server.handleRepoToken(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.Code)
	}

	var payload tokenResponse
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if payload.Token == "" {
		t.Fatalf("token should not be empty")
	}

	if _, err := time.Parse(time.RFC3339, payload.ExpiresAt); err != nil {
		t.Fatalf("invalid expires_at: %v", err)
	}
}

// TestHandleRepoTokenUnknownRepo verifies structured unknown-repo errors.
func TestHandleRepoTokenUnknownRepo(t *testing.T) {
	fakeAPI := newFakeGitHubAPI()

	server := &apiServer{
		broker: newTestBroker(t, fakeAPI),
	}

	request := httptest.NewRequest(
		http.MethodGet,
		"/repos/test/missing/token",
		nil,
	)
	response := httptest.NewRecorder()
	server.handleRepoToken(response, request)

	if response.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", response.Code)
	}

	var payload errorResponse
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if payload.Kind != errorKindUnknownInstallation {
		t.Fatalf(
			"expected kind %q, got %q",
			errorKindUnknownInstallation,
			payload.Kind,
		)
	}
}

// fakeGitHubAPI is an in-memory GitHub API stub with call counters.
type fakeGitHubAPI struct {
	mu sync.Mutex
	// installationCalls maps "OWNER/REPO" -> number of installation lookups.
	installationCalls map[string]int
	// tokenCallsByInstall maps installation_id -> number of token mints.
	tokenCallsByInstall map[int64]int
}

// newFakeGitHubAPI creates a new in-memory GitHub API stub.
func newFakeGitHubAPI() *fakeGitHubAPI {
	return &fakeGitHubAPI{
		installationCalls:   make(map[string]int),
		tokenCallsByInstall: make(map[int64]int),
	}
}

// installationCallsFor returns lookup calls made for one repo.
func (a *fakeGitHubAPI) installationCallsFor(fullRepo string) int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.installationCalls[fullRepo]
}

// tokenCallsFor returns token-mint calls made for one installation id.
func (a *fakeGitHubAPI) tokenCallsFor(installationID int64) int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.tokenCallsByInstall[installationID]
}

// roundTrip routes one outgoing request to the in-memory stub handlers.
func (a *fakeGitHubAPI) roundTrip(
	request *http.Request,
) (*http.Response, error) {
	if !strings.HasPrefix(request.Header.Get("Authorization"), "Bearer ") {
		return jsonResponse(
			http.StatusUnauthorized,
			`{"message":"missing bearer token"}`,
		), nil
	}

	switch {
	case strings.HasPrefix(request.URL.Path, "/repos/"):
		return a.handleInstallationLookup(request), nil
	case strings.HasPrefix(request.URL.Path, "/app/installations/"):
		return a.handleAccessTokenMint(request), nil
	default:
		return jsonResponse(http.StatusNotFound, `{"message":"not found"}`), nil
	}
}

// handleInstallationLookup handles fake installation lookup requests.
func (a *fakeGitHubAPI) handleInstallationLookup(
	request *http.Request,
) *http.Response {
	if request.Method != http.MethodGet {
		return jsonResponse(
			http.StatusMethodNotAllowed,
			`{"message":"method not allowed"}`,
		)
	}

	parts := strings.Split(strings.Trim(request.URL.Path, "/"), "/")
	if len(parts) != 4 || parts[0] != "repos" || parts[3] != "installation" {
		return jsonResponse(http.StatusNotFound, `{"message":"not found"}`)
	}

	fullRepo := parts[1] + "/" + parts[2]
	a.mu.Lock()
	a.installationCalls[fullRepo]++
	call := a.installationCalls[fullRepo]
	a.mu.Unlock()

	switch fullRepo {
	case "test/repo":
		return jsonResponse(http.StatusOK, `{"id":101}`)
	case "test/missing":
		return jsonResponse(http.StatusNotFound, `{"message":"not found"}`)
	case "test/stale":
		// First lookup returns an installation that then disappears.
		if call == 1 {
			return jsonResponse(http.StatusOK, `{"id":200}`)
		}
		return jsonResponse(http.StatusOK, `{"id":201}`)
	default:
		return jsonResponse(http.StatusNotFound, `{"message":"not found"}`)
	}
}

// handleAccessTokenMint handles fake access-token mint requests.
func (a *fakeGitHubAPI) handleAccessTokenMint(
	request *http.Request,
) *http.Response {
	if request.Method != http.MethodPost {
		return jsonResponse(
			http.StatusMethodNotAllowed,
			`{"message":"method not allowed"}`,
		)
	}

	parts := strings.Split(strings.Trim(request.URL.Path, "/"), "/")
	if len(parts) != 4 ||
		parts[0] != "app" ||
		parts[1] != "installations" ||
		parts[3] != "access_tokens" {
		return jsonResponse(http.StatusNotFound, `{"message":"not found"}`)
	}

	installationID, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil {
		return jsonResponse(http.StatusBadRequest, `{"message":"bad id"}`)
	}

	a.mu.Lock()
	a.tokenCallsByInstall[installationID]++
	tokenCall := a.tokenCallsByInstall[installationID]
	a.mu.Unlock()

	var body accessTokenRequest
	if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
		return jsonResponse(http.StatusBadRequest, `{"message":"invalid json"}`)
	}
	if len(body.Repositories) != 1 {
		return jsonResponse(http.StatusBadRequest, `{"message":"missing scope"}`)
	}

	switch installationID {
	case 101:
		return jsonResponse(http.StatusCreated, tokenJSON("repo-token-1"))
	case 200:
		return jsonResponse(http.StatusNotFound, `{"message":"not found"}`)
	case 201:
		if tokenCall != 1 {
			return jsonResponse(
				http.StatusInternalServerError,
				`{"message":"unexpected retry count"}`,
			)
		}
		return jsonResponse(http.StatusCreated, tokenJSON("stale-token-1"))
	default:
		return jsonResponse(http.StatusNotFound, `{"message":"not found"}`)
	}
}

// roundTripperFunc adapts a func into an http.RoundTripper.
type roundTripperFunc func(*http.Request) (*http.Response, error)

// RoundTrip dispatches one request through the wrapped function.
func (fn roundTripperFunc) RoundTrip(
	request *http.Request,
) (*http.Response, error) {
	return fn(request)
}

// client returns an http.Client that routes requests to this fake API.
func (a *fakeGitHubAPI) client() *http.Client {
	return &http.Client{
		Transport: roundTripperFunc(a.roundTrip),
		Timeout:   15 * time.Second,
	}
}

// jsonResponse creates a JSON HTTP response for in-memory roundtrips.
func jsonResponse(status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Header: http.Header{
			"Content-Type": []string{"application/json"},
		},
		Body: io.NopCloser(strings.NewReader(body)),
	}
}

// tokenJSON returns a token payload string with a near-future expiration.
func tokenJSON(token string) string {
	expiresAt := time.Now().Add(1 * time.Hour).UTC().Format(time.RFC3339)
	return `{"token":"` + token + `","expires_at":"` + expiresAt + `"}`
}

// newTestBroker creates a broker wired to the fake GitHub API.
func newTestBroker(t *testing.T, fakeAPI *fakeGitHubAPI) *broker {
	t.Helper()

	privateKeyPath := writeRSAPrivateKeyPEM(t)
	privateKey, err := readPrivateKey(privateKeyPath)
	if err != nil {
		t.Fatalf("readPrivateKey: %v", err)
	}

	broker := newBroker(
		config{
			GitHubAPIBase:        "https://api.github.test",
			AppID:                "12345",
			AppKeyPath:           privateKeyPath,
			InstallationCacheTTL: 5 * time.Minute,
		},
		privateKey,
	)

	broker.client = fakeAPI.client()
	return broker
}

// writeRSAPrivateKeyPEM writes a generated RSA private key to a temp file.
func writeRSAPrivateKeyPEM(t *testing.T) string {
	t.Helper()

	privateKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}

	encoded := pem.EncodeToMemory(&pem.Block{
		Type:  "RSA PRIVATE KEY",
		Bytes: x509.MarshalPKCS1PrivateKey(privateKey),
	})

	path := filepath.Join(t.TempDir(), "app-key.pem")
	if err := os.WriteFile(path, encoded, 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	return path
}
