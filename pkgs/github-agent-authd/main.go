// github-agent-authd is a local GitHub App installation-token broker.
//
// It authenticates as a GitHub App, resolves repository installation IDs,
// mints short-lived installation tokens, caches both installation lookups
// and minted tokens in memory, then returns tokens to local callers.
//
// Local API (over Unix socket):
//   - GET /healthz
//   - GET /repos/{owner}/{repo}/token
//
// Environment variables:
//   - GITHUB_API_BASE (default: https://api.github.com)
//   - APP_ID (required)
//   - APP_KEY_PATH (required; supports %d/ prefix)
//   - INSTALLATION_CACHE_TTL (default: 5m)
//   - IDLE_SHUTDOWN_TIMEOUT (default: 30m)
//
// Socket activation:
//   - primary: systemd LISTEN_FDS/LISTEN_PID (fd 3)
//   - fallback for local dev: LISTEN_SOCKET=/path/to/socket
//
// APP_KEY_PATH supports `%d/`, expanding to `$CREDENTIALS_DIRECTORY/`.
//
// See also:
//   - doc/github-agent-access/02-implementation.md
//   - nixos/mods/github-agent-authd.nix
//   - nixos/tests/github-agent-authd.nix
//   - pkgs/github-agent-authd/default.nix
package main

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	// the default upstream GitHub API endpoint.
	defaultGitHubAPIBase = "https://api.github.com"

	// the default TTL for install lookups.
	defaultInstallationCacheTTL = 5 * time.Minute

	// auto-shutdown the daemon after this much local API inactivity.
	defaultIdleShutdownTimeout = 30 * time.Minute

	// refresh tokens that are near expiration.
	tokenRefreshWindow = 10 * time.Minute

	// timeout for local API requests e2e.
	localRequestTimeout = 20 * time.Second

	// timeout for upstream GitHub requests e2e.
	upstreamHTTPTimeout = 15 * time.Second

	// errorBodyLimitBytes caps upstream error body reads for logs/errors.
	errorBodyLimitBytes = 4096
)

const (
	// repo has no visible app installation.
	errorKindUnknownInstallation = "unknown_installation"

	// app-level auth failed (JWT/permissions).
	errorKindAppAuth = "app_auth_failure"

	// a generic GitHub API failure.
	errorKindUpstream = "github_api_failure"

	// cached installation id is stale.
	errorKindStaleInstallation = "stale_installation"

	// malformed local API request.
	errorKindInvalidRequest = "invalid_request"

	// unexpected local service error.
	errorKindInternal = "internal"
)

// cacheOutcome classifies where install/token state came from.
type cacheOutcome uint8

const (
	// cache satisfied the request.
	cacheOutcomePositiveHit cacheOutcome = iota

	// cached "repo missing install" hit.
	cacheOutcomeNegativeHit

	// upstream lookup/mint was required.
	cacheOutcomeMiss
)

// config holds runtime daemon configuration from environment variables.
type config struct {
	GitHubAPIBase        string
	AppID                string
	AppKeyPath           string
	InstallationCacheTTL time.Duration
	IdleShutdownTimeout  time.Duration
}

// apiServer owns local HTTP handlers and broker integration.
type apiServer struct {
	broker *broker

	idleShutdownTimeout time.Duration

	mu               sync.Mutex
	inFlightRequests int
	lastActivity     time.Time
}

// minimal shutdown behavior required by idle monitor.
type shutdowner interface {
	Shutdown(context.Context) error
}

// broker mints tokens and owns all in-memory caches/state.
type broker struct {
	cfg    config
	key    *rsa.PrivateKey
	client *http.Client

	mu sync.Mutex
	// installationCache maps "OWNER/REPO" -> installation metadata.
	installationCache map[string]installationCacheEntry
	// tokenCache maps "{installation_id, OWNER/REPO}" -> token metadata.
	tokenCache map[tokenCacheKey]tokenCacheEntry
}

// wraps lower-level errors with stable kinds.
type brokerError struct {
	kind string
	err  error
}

// one installation cache record.
type installationCacheEntry struct {
	installationID int64
	expiresAt      time.Time
	negative       bool
}

// one downscoped installation token cache entry.
type tokenCacheKey struct {
	installationID int64
	fullRepo       string
}

// one minted-token cache record.
type tokenCacheEntry struct {
	token     string
	expiresAt time.Time
}

// the broker's successful token lookup result.
type tokenResult struct {
	Token          string
	ExpiresAt      time.Time
	InstallationID int64
	CacheOutcome   cacheOutcome
}

// the daemon's successful HTTP response payload.
type tokenResponse struct {
	Token     string `json:"token"`
	ExpiresAt string `json:"expires_at"`
}

// the daemon's structured HTTP error payload.
type errorResponse struct {
	Error string `json:"error"`
	Kind  string `json:"kind"`
}

// GitHub `GET /repos/{owner}/{repo}/installation` response body type.
type appInstallationResponse struct {
	ID int64 `json:"id"`
}

// GitHub `POST /app/installations/{installation_id}/access_tokens" request
// body type.
type accessTokenRequest struct {
	Repositories []string `json:"repositories"`
}

// GitHub `POST /app/installations/{installation_id}/access_tokens" response
// body type containing a newly minted access token.
type accessTokenResponse struct {
	Token     string    `json:"token"`
	ExpiresAt time.Time `json:"expires_at"`
}

// main loads configuration, initializes the broker, and serves local HTTP.
func main() {
	// Keep logs raw. journald already annotates with timestamps/metadata.
	log.SetFlags(0)

	cfg, err := loadConfigFromEnv()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	privateKey, err := readPrivateKey(cfg.AppKeyPath)
	if err != nil {
		log.Fatalf("read app private key: %v", err)
	}

	listener, err := openListener()
	if err != nil {
		log.Fatalf("open listener: %v", err)
	}
	defer listener.Close()

	srv := newAPIServer(newBroker(cfg, privateKey), cfg.IdleShutdownTimeout)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", srv.handleHealthz)
	mux.HandleFunc("/repos/", srv.handleRepoToken)

	server := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    8 << 10, // 8 KiB
	}

	srv.startIdleShutdownMonitor(server)

	log.Printf(
		"github-agent-authd: ready idle_shutdown_timeout=%s",
		cfg.IdleShutdownTimeout,
	)

	if err := server.Serve(listener); err != nil &&
		!errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("http server: %v", err)
	}
}

// parse daemon `config` from environment variables.
func loadConfigFromEnv() (config, error) {
	cfg := config{
		GitHubAPIBase: strings.TrimRight(
			getEnvDefault("GITHUB_API_BASE", defaultGitHubAPIBase),
			"/",
		),
		AppID: strings.TrimSpace(os.Getenv("APP_ID")),
	}

	// Required GitHub App identity inputs.
	if cfg.AppID == "" {
		return cfg, fmt.Errorf("APP_ID is required")
	}

	rawPath := strings.TrimSpace(os.Getenv("APP_KEY_PATH"))
	if rawPath == "" {
		return cfg, fmt.Errorf("APP_KEY_PATH is required")
	}

	// Expand %d/ path prefix from systemd LoadCredential.
	expandedPath, err := expandCredentialPath(rawPath)
	if err != nil {
		return cfg, err
	}
	cfg.AppKeyPath = expandedPath

	// Parse cache TTL.
	cfg.InstallationCacheTTL, err = parseDurationEnv(
		"INSTALLATION_CACHE_TTL",
		defaultInstallationCacheTTL,
	)
	if err != nil {
		return cfg, err
	}

	cfg.IdleShutdownTimeout, err = parseDurationEnv(
		"IDLE_SHUTDOWN_TIMEOUT",
		defaultIdleShutdownTimeout,
	)
	if err != nil {
		return cfg, err
	}

	return cfg, nil
}

// construct an apiServer with initialized idle-activity state.
func newAPIServer(broker *broker, idleShutdownTimeout time.Duration) *apiServer {
	return &apiServer{
		broker:              broker,
		idleShutdownTimeout: idleShutdownTimeout,
		lastActivity:        time.Now(),
	}
}

// background monitor that self-shuts down the daemon on extended idleness.
func (s *apiServer) startIdleShutdownMonitor(server shutdowner) {
	if s.idleShutdownTimeout <= 0 {
		return
	}

	checkInterval := min(s.idleShutdownTimeout, 1 * time.Minute)

	go func() {
		ticker := time.NewTicker(checkInterval)
		defer ticker.Stop()

		for range ticker.C {
			inFlightRequests, lastActivity := s.idleSnapshot()
			idleFor := time.Since(lastActivity)
			if inFlightRequests != 0 || idleFor < s.idleShutdownTimeout {
				continue
			}

			log.Printf(
				"idle shutdown: idle_for=%s timeout=%s",
				idleFor,
				s.idleShutdownTimeout,
			)

			shutdownCtx, cancel := context.WithTimeout(
				context.Background(),
				10*time.Second,
			)
			err := server.Shutdown(shutdownCtx)
			cancel()
			if err != nil {
				log.Printf("idle shutdown error: %v", err)
			}
			return
		}
	}()
}

// track one request entering handler execution.
func (s *apiServer) beginRequest() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.inFlightRequests++
	s.lastActivity = time.Now()
}

// track one request leaving handler execution.
func (s *apiServer) endRequest() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.inFlightRequests > 0 {
		s.inFlightRequests--
	}
	s.lastActivity = time.Now()
}

// read a coherent idleness snapshot.
func (s *apiServer) idleSnapshot() (inFlightRequests int, lastActivity time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.inFlightRequests, s.lastActivity
}

// return env var `${key}` value or `fallback` when not present.
func getEnvDefault(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}
	return value
}

// parse a duration env var `${key}` with a validated fallback.
func parseDurationEnv(key string, fallback time.Duration) (
	time.Duration,
	error,
) {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback, nil
	}

	duration, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("invalid %s: %w", key, err)
	}

	if duration <= 0 {
		return 0, fmt.Errorf("%s must be > 0", key)
	}

	return duration, nil
}

// resolve %d/ prefix via $CREDENTIALS_DIRECTORY.
func expandCredentialPath(path string) (string, error) {
	if !strings.HasPrefix(path, "%d/") {
		return path, nil
	}

	credentialsDir := strings.TrimSpace(os.Getenv("CREDENTIALS_DIRECTORY"))
	if credentialsDir == "" {
		return "", fmt.Errorf(
			"APP_KEY_PATH %q uses %%d/ but CREDENTIALS_DIRECTORY is empty",
			path,
		)
	}

	relPath := strings.TrimPrefix(path, "%d/")
	return filepath.Join(credentialsDir, relPath), nil
}

// load a PEM-encoded RSA key (PKCS#1 or PKCS#8).
func readPrivateKey(path string) (*rsa.PrivateKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %q: %w", path, err)
	}

	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, fmt.Errorf("no PEM block found in %q", path)
	}

	if key, parseErr := x509.ParsePKCS1PrivateKey(block.Bytes); parseErr == nil {
		return key, nil
	}

	privateKey, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse private key: %w", err)
	}

	rsaKey, ok := privateKey.(*rsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("private key in %q is not RSA", path)
	}
	return rsaKey, nil
}

// resolve unix socket from systemd socket activation or $LISTEN_SOCKET.
func openListener() (net.Listener, error) {
	if listener, err := openSystemdListener(); err == nil {
		return listener, nil
	}

	socketPath := strings.TrimSpace(os.Getenv("LISTEN_SOCKET"))
	if socketPath == "" {
		return nil, fmt.Errorf(
			"systemd socket activation unavailable and LISTEN_SOCKET is unset",
		)
	}

	_ = os.Remove(socketPath)
	return net.Listen("unix", socketPath)
}

// opens LISTEN_FDS fd=3 from systemd activation.
func openSystemdListener() (net.Listener, error) {
	if os.Getenv("LISTEN_FDS") != "1" {
		return nil, fmt.Errorf("LISTEN_FDS is not 1")
	}
	if os.Getenv("LISTEN_PID") != strconv.Itoa(os.Getpid()) {
		return nil, fmt.Errorf("LISTEN_PID does not match")
	}

	file := os.NewFile(uintptr(3), "systemd-listen-fd")
	if file == nil {
		return nil, fmt.Errorf("fd 3 unavailable")
	}

	listener, err := net.FileListener(file)
	if err != nil {
		_ = file.Close()
		return nil, fmt.Errorf("wrap fd 3: %w", err)
	}

	return listener, nil
}

// create a `broker` with hardened upstream HTTP client defaults.
func newBroker(cfg config, key *rsa.PrivateKey) *broker {
	return &broker{
		cfg:               cfg,
		key:               key,
		client:            newUpstreamHTTPClient(),
		installationCache: make(map[string]installationCacheEntry),
		tokenCache:        make(map[tokenCacheKey]tokenCacheEntry),
	}
}

// build the client used for GitHub API requests.
func newUpstreamHTTPClient() *http.Client {
	dialer := &net.Dialer{Timeout: upstreamHTTPTimeout}

	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           dialer.DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          8,
		MaxIdleConnsPerHost:   8,
		IdleConnTimeout:       30 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
	}

	return &http.Client{
		Transport: transport,
		Timeout:   upstreamHTTPTimeout,
	}
}

// report daemon health for local readiness probes.
func (s *apiServer) handleHealthz(
	writer http.ResponseWriter,
	request *http.Request,
) {
	s.beginRequest()
	defer s.endRequest()

	if request.Method != http.MethodGet {
		writeJSONError(
			writer,
			http.StatusMethodNotAllowed,
			errorKindInvalidRequest,
			"method not allowed",
		)
		return
	}

	writer.WriteHeader(http.StatusOK)
	_, _ = writer.Write([]byte("ok\n"))
}

// return a repo-scoped installation token as JSON.
func (s *apiServer) handleRepoToken(
	writer http.ResponseWriter,
	request *http.Request,
) {
	s.beginRequest()
	defer s.endRequest()

	// Validate request envelope first.
	if request.Method != http.MethodGet {
		writeJSONError(
			writer,
			http.StatusMethodNotAllowed,
			errorKindInvalidRequest,
			"method not allowed",
		)
		return
	}

	owner, repo, ok := parseTokenPath(request.URL.Path)
	if !ok {
		writeJSONError(
			writer,
			http.StatusNotFound,
			errorKindInvalidRequest,
			"unknown endpoint",
		)
		return
	}

	// Bound the whole operation so hung upstreams/clients fail closed.
	requestCtx, cancel := context.WithTimeout(
		request.Context(),
		localRequestTimeout,
	)
	defer cancel()

	// Resolve token
	start := time.Now()
	result, err := s.broker.tokenForRepo(requestCtx, owner, repo)
	latencyMs := time.Since(start).Milliseconds()
	fullRepo := owner + "/" + repo
	if err != nil {
		status, kind := mapError(err)
		log.Printf(
			"repo=%s latency_ms=%d kind=%s err=%q",
			fullRepo,
			latencyMs,
			kind,
			err.Error(),
		)
		writeJSONError(writer, status, kind, err.Error())
		return
	}

	log.Printf(
		"repo=%s installation_id=%d cache_outcome=%s latency_ms=%d",
		fullRepo,
		result.InstallationID,
		result.CacheOutcome.String(),
		latencyMs,
	)

	// Return token payload on success.
	writeJSON(writer, http.StatusOK, tokenResponse{
		Token:     result.Token,
		ExpiresAt: result.ExpiresAt.UTC().Format(time.RFC3339),
	})
}

// parse "/repos/{owner}/{repo}/token".
func parseTokenPath(path string) (owner string, repo string, ok bool) {
	if !strings.HasPrefix(path, "/repos/") {
		return "", "", false
	}

	trimmed := strings.TrimPrefix(path, "/repos/")
	parts := strings.Split(trimmed, "/")
	if len(parts) != 3 {
		return "", "", false
	}

	if parts[2] != "token" || parts[0] == "" || parts[1] == "" {
		return "", "", false
	}

	return parts[0], parts[1], true
}

// map broker failures to stable HTTP status/kind outputs.
func mapError(err error) (statusCode int, kind string) {
	switch {
	case isErrorKind(err, errorKindUnknownInstallation):
		return http.StatusNotFound, errorKindUnknownInstallation
	case isErrorKind(err, errorKindAppAuth):
		return http.StatusBadGateway, errorKindAppAuth
	case isErrorKind(err, errorKindStaleInstallation):
		return http.StatusBadGateway, errorKindStaleInstallation
	case isErrorKind(err, errorKindUpstream):
		return http.StatusBadGateway, errorKindUpstream
	default:
		return http.StatusInternalServerError, errorKindInternal
	}
}

// write a structured error response.
func writeJSONError(
	writer http.ResponseWriter,
	statusCode int,
	kind string,
	message string,
) {
	writeJSON(writer, statusCode, errorResponse{
		Error: message,
		Kind:  kind,
	})
}

// write one JSON response payload.
func writeJSON(writer http.ResponseWriter, statusCode int, payload any) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(statusCode)

	encoder := json.NewEncoder(writer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(payload); err != nil {
		log.Printf("response encode error: %v", err)
	}
}

// resolve/mint a repo-scoped installation token.
func (b *broker) tokenForRepo(
	ctx context.Context,
	owner string,
	repo string,
) (tokenResult, error) {
	fullRepo := owner + "/" + repo

	// resolve installation id (cached when possible).
	installationID, installCacheOutcome, err := b.installationIDForRepo(
		ctx,
		owner,
		repo,
	)
	if err != nil {
		return tokenResult{}, err
	}

	// resolve token (cached when possible).
	result, err := b.cachedOrMintedToken(
		ctx,
		installationID,
		fullRepo,
		repo,
		installCacheOutcome,
	)
	if err == nil {
		return result, nil
	}

	// stale installation ids can happen after app install changes.
	if !isErrorKind(err, errorKindStaleInstallation) {
		return tokenResult{}, err
	}
	b.invalidateInstallationCache(fullRepo)

	// rediscover once and retry mint.
	installationID, installCacheOutcome, err = b.installationIDForRepo(
		ctx,
		owner,
		repo,
	)
	if err != nil {
		return tokenResult{}, err
	}

	return b.cachedOrMintedToken(
		ctx,
		installationID,
		fullRepo,
		repo,
		installCacheOutcome,
	)
}

// resolve OWNER/REPO -> installation_id with caching.
func (b *broker) installationIDForRepo(
	ctx context.Context,
	owner string,
	repo string,
) (int64, cacheOutcome, error) {
	fullRepo := owner + "/" + repo
	now := time.Now()

	// Check cached install id (positive or negative).
	b.mu.Lock()
	cached, found := b.installationCache[fullRepo]
	if found && now.Before(cached.expiresAt) {
		b.mu.Unlock()
		if cached.negative {
			return 0, cacheOutcomeNegativeHit, newBrokerError(
				errorKindUnknownInstallation,
				"unknown repo/installation: %s",
				fullRepo,
			)
		}
		return cached.installationID, cacheOutcomePositiveHit, nil
	}
	b.mu.Unlock()

	// Cache miss: lookup installation upstream.
	installationID, err := b.fetchInstallationID(ctx, owner, repo)
	if err != nil {
		if isErrorKind(err, errorKindUnknownInstallation) {
			b.mu.Lock()
			b.installationCache[fullRepo] = installationCacheEntry{
				negative:  true,
				expiresAt: now.Add(b.cfg.InstallationCacheTTL),
			}
			b.mu.Unlock()
		}
		return 0, cacheOutcomeMiss, err
	}

	// Save successful lookup in cache.
	b.mu.Lock()
	b.installationCache[fullRepo] = installationCacheEntry{
		installationID: installationID,
		expiresAt:      now.Add(b.cfg.InstallationCacheTTL),
	}
	b.mu.Unlock()

	return installationID, cacheOutcomeMiss, nil
}

// call GET /repos/{owner}/{repo}/installation.
func (b *broker) fetchInstallationID(
	ctx context.Context,
	owner string,
	repo string,
) (int64, error) {
	jwtToken, err := b.appJWT(time.Now())
	if err != nil {
		return 0, newBrokerError(errorKindAppAuth, "sign app jwt: %v", err)
	}

	endpoint := fmt.Sprintf(
		"%s/repos/%s/%s/installation",
		b.cfg.GitHubAPIBase,
		url.PathEscape(owner),
		url.PathEscape(repo),
	)

	// Bound upstream request lifetime under the caller context.
	requestCtx, cancel := context.WithTimeout(ctx, upstreamHTTPTimeout)
	defer cancel()

	request, err := http.NewRequestWithContext(
		requestCtx,
		http.MethodGet,
		endpoint,
		nil,
	)
	if err != nil {
		return 0, newBrokerError(
			errorKindInternal,
			"build installation request: %v",
			err,
		)
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("Authorization", "Bearer "+jwtToken)

	response, err := b.client.Do(request)
	if err != nil {
		return 0, newBrokerError(
			errorKindUpstream,
			"request installation endpoint: %v",
			err,
		)
	}
	defer response.Body.Close()

	switch response.StatusCode {
	case http.StatusOK:
	case http.StatusNotFound:
		return 0, newBrokerError(
			errorKindUnknownInstallation,
			"unknown repo/installation: %s/%s",
			owner,
			repo,
		)
	case http.StatusUnauthorized, http.StatusForbidden:
		return 0, newBrokerError(
			errorKindAppAuth,
			"installation lookup rejected: HTTP %d",
			response.StatusCode,
		)
	default:
		body := readErrorBody(response.Body)
		return 0, newBrokerError(
			errorKindUpstream,
			"installation lookup failed: HTTP %d: %s",
			response.StatusCode,
			body,
		)
	}

	var payload appInstallationResponse
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		return 0, newBrokerError(
			errorKindUpstream,
			"decode installation response: %v",
			err,
		)
	}

	if payload.ID <= 0 {
		return 0, newBrokerError(
			errorKindUpstream,
			"invalid installation id: %d",
			payload.ID,
		)
	}

	return payload.ID, nil
}

// return a fresh-enough cached token or mint a new one.
func (b *broker) cachedOrMintedToken(
	ctx context.Context,
	installationID int64,
	fullRepo string,
	repo string,
	installCacheOutcome cacheOutcome,
) (tokenResult, error) {
	key := tokenCacheKey{
		installationID: installationID,
		fullRepo:       fullRepo,
	}

	// Prefer cached token when enough lifetime remains.
	b.mu.Lock()
	cachedToken, found := b.tokenCache[key]
	if found && time.Until(cachedToken.expiresAt) > tokenRefreshWindow {
		b.mu.Unlock()
		return tokenResult{
			Token:          cachedToken.token,
			ExpiresAt:      cachedToken.expiresAt,
			InstallationID: installationID,
			CacheOutcome:   cacheOutcomePositiveHit,
		}, nil
	}
	b.mu.Unlock()

	// Mint and cache a new downscoped token.
	mintedToken, err := b.mintInstallationToken(ctx, installationID, repo)
	if err != nil {
		return tokenResult{}, err
	}

	b.mu.Lock()
	b.tokenCache[key] = tokenCacheEntry{
		token:     mintedToken.Token,
		expiresAt: mintedToken.ExpiresAt,
	}
	b.mu.Unlock()

	return tokenResult{
		Token:          mintedToken.Token,
		ExpiresAt:      mintedToken.ExpiresAt,
		InstallationID: installationID,
		CacheOutcome:   installCacheOutcome,
	}, nil
}

// call POST /app/installations/{id}/access_tokens.
func (b *broker) mintInstallationToken(
	ctx context.Context,
	installationID int64,
	repo string,
) (accessTokenResponse, error) {
	jwtToken, err := b.appJWT(time.Now())
	if err != nil {
		return accessTokenResponse{}, newBrokerError(
			errorKindAppAuth,
			"sign app jwt: %v",
			err,
		)
	}

	endpoint := fmt.Sprintf(
		"%s/app/installations/%d/access_tokens",
		b.cfg.GitHubAPIBase,
		installationID,
	)

	payload, err := json.Marshal(accessTokenRequest{
		Repositories: []string{repo},
	})
	if err != nil {
		return accessTokenResponse{}, newBrokerError(
			errorKindInternal,
			"encode token request: %v",
			err,
		)
	}

	// Bound upstream request lifetime under the caller context.
	requestCtx, cancel := context.WithTimeout(ctx, upstreamHTTPTimeout)
	defer cancel()

	request, err := http.NewRequestWithContext(
		requestCtx,
		http.MethodPost,
		endpoint,
		strings.NewReader(string(payload)),
	)
	if err != nil {
		return accessTokenResponse{}, newBrokerError(
			errorKindInternal,
			"build token request: %v",
			err,
		)
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("Authorization", "Bearer "+jwtToken)
	request.Header.Set("Content-Type", "application/json")

	response, err := b.client.Do(request)
	if err != nil {
		return accessTokenResponse{}, newBrokerError(
			errorKindUpstream,
			"request token endpoint: %v",
			err,
		)
	}
	defer response.Body.Close()

	switch response.StatusCode {
	case http.StatusCreated:
	case http.StatusNotFound:
		return accessTokenResponse{}, newBrokerError(
			errorKindStaleInstallation,
			"installation %d not found while minting token",
			installationID,
		)
	case http.StatusUnauthorized, http.StatusForbidden:
		return accessTokenResponse{}, newBrokerError(
			errorKindAppAuth,
			"token mint rejected: HTTP %d",
			response.StatusCode,
		)
	default:
		body := readErrorBody(response.Body)
		return accessTokenResponse{}, newBrokerError(
			errorKindUpstream,
			"token mint failed: HTTP %d: %s",
			response.StatusCode,
			body,
		)
	}

	var tokenPayload accessTokenResponse
	if err := json.NewDecoder(response.Body).Decode(&tokenPayload); err != nil {
		return accessTokenResponse{}, newBrokerError(
			errorKindUpstream,
			"decode token response: %v",
			err,
		)
	}

	if tokenPayload.Token == "" {
		return accessTokenResponse{}, newBrokerError(
			errorKindUpstream,
			"token response missing token",
		)
	}

	return tokenPayload, nil
}

// read and trim a bounded upstream error body.
func readErrorBody(reader io.Reader) string {
	body, err := io.ReadAll(io.LimitReader(reader, errorBodyLimitBytes))
	if err != nil {
		return "<read error>"
	}
	return strings.TrimSpace(string(body))
}

// drop one cached OWNER/REPO install entry.
func (b *broker) invalidateInstallationCache(fullRepo string) {
	b.mu.Lock()
	delete(b.installationCache, fullRepo)
	b.mu.Unlock()
}

// sign a short-lived JWT for GitHub App authentication.
func (b *broker) appJWT(now time.Time) (string, error) {
	headerJSON := []byte(`{"alg":"RS256","typ":"JWT"}`)
	payload := map[string]any{
		"iat": now.Add(-60 * time.Second).Unix(),
		"exp": now.Add(9 * time.Minute).Unix(),
		"iss": b.cfg.AppID,
	}

	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		return "", fmt.Errorf("marshal jwt payload: %w", err)
	}

	encode := base64.RawURLEncoding.EncodeToString
	signingInput := encode(headerJSON) + "." + encode(payloadJSON)

	digest := sha256.Sum256([]byte(signingInput))
	signature, err := rsa.SignPKCS1v15(
		rand.Reader,
		b.key,
		crypto.SHA256,
		digest[:],
	)
	if err != nil {
		return "", fmt.Errorf("sign jwt: %w", err)
	}

	return signingInput + "." + encode(signature), nil
}

func (e *brokerError) Error() string {
	return e.err.Error()
}

func (e *brokerError) Unwrap() error {
	return e.err
}

func newBrokerError(kind string, format string, args ...any) error {
	return &brokerError{
		kind: kind,
		err:  fmt.Errorf(format, args...),
	}
}

// return whether err is a brokerError with a given kind.
func isErrorKind(err error, kind string) bool {
	var bErr *brokerError
	if !errors.As(err, &bErr) {
		return false
	}
	return bErr.kind == kind
}

// return a stable string for logs and API-adjacent diagnostics.
func (outcome cacheOutcome) String() string {
	switch outcome {
	case cacheOutcomePositiveHit:
		return "positive_hit"
	case cacheOutcomeNegativeHit:
		return "negative_hit"
	case cacheOutcomeMiss:
		return "miss"
	default:
		return "unknown"
	}
}
