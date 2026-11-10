package main

import (
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

// rawRequest sends `request` over a fresh connection and returns everything
// the server writes before it closes the connection. The error is a reset,
// ex: the server closed w/ request bytes unread.
func rawRequest(t *testing.T, url, request string) (string, error) {
	t.Helper()
	conn, err := net.Dial("tcp", strings.TrimPrefix(url, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	// The server must close first; don't hang if it doesn't.
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))

	if _, err := io.WriteString(conn, request); err != nil {
		return "", err
	}
	resp, err := io.ReadAll(conn)
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		t.Fatalf("server didn't close the connection (got %q)", resp)
	}
	return string(resp), err
}

// TestServerHTTP verifies statuses, HEAD, and headers through Go's client.
func TestServerHTTP(t *testing.T) {
	url := newFakeHost(t).serve(1)

	// GET, w/ a query string, which is ignored.
	resp, err := http.Get(url + "/metrics?x=1")
	if err != nil {
		t.Fatal(err)
	}
	body, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil || resp.StatusCode != http.StatusOK ||
		!strings.Contains(string(body), "nixos_boots_total 1\n") {
		t.Fatalf("GET: %d %v %q", resp.StatusCode, err, body)
	}
	contentType := resp.Header.Get("Content-Type")
	if !strings.HasPrefix(contentType, "text/plain; version=0.0.4") {
		t.Fatalf("GET: Content-Type %q", contentType)
	}

	// HEAD: same length, no body.
	resp, err = http.Head(url + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK ||
		resp.ContentLength != int64(len(body)) {
		t.Fatalf("HEAD: %d, length %d, want %d",
			resp.StatusCode, resp.ContentLength, len(body))
	}

	// Only /metrics, only GET + HEAD.
	resp, err = http.Get(url + "/")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("GET /: expected 404, got %d", resp.StatusCode)
	}
	resp, err = http.Post(url+"/metrics", "text/plain", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed ||
		resp.Header.Get("Allow") != "GET, HEAD" {
		t.Fatalf("POST: expected 405 + Allow, got %d %v",
			resp.StatusCode, resp.Header)
	}
}

// TestServerBadRequests verifies malformed and oversized requests get a 400
// or a closed connection, never a hang.
func TestServerBadRequests(t *testing.T) {
	url := newFakeHost(t).serve(1)

	// Malformed request lines.
	for _, line := range []string{
		"garbage", "GET /metrics", "GET /metrics SPDY/3",
		"GET / metrics HTTP/1.1",
	} {
		resp, err := rawRequest(t, url, line+"\r\n\r\n")
		if err != nil || !strings.HasPrefix(resp, "HTTP/1.1 400 ") {
			t.Fatalf("%q: %q, %v", line, resp, err)
		}
	}

	// Too long: in total (past maxRequestBytes), or one line (past the
	// read buffer). Closed w/o a response.
	pad := func(count, size int) string {
		line := "X-Pad: " + strings.Repeat("a", size) + "\r\n"
		return strings.Repeat(line, count)
	}
	for name, headers := range map[string]string{
		"total": pad(100, 1000),
		"line":  pad(1, 5000),
	} {
		resp, _ := rawRequest(t, url, "GET /metrics HTTP/1.1\r\n"+headers)
		if resp != "" {
			t.Fatalf("too long %s: expected no response, got %q",
				name, resp[:min(len(resp), 40)])
		}
	}

	// A stalled request: closed at the deadline.
	fastURL := newFakeHost(t).serveTimeout(1, 50*time.Millisecond)
	stalled := "GET /metrics HTTP/1.1\r\n"
	if resp, _ := rawRequest(t, fastURL, stalled); resp != "" {
		t.Fatalf("stalled: expected no response, got %q", resp)
	}

	// HEAD: no body after the headers. Go's client wouldn't notice one.
	resp, err := rawRequest(t, url, "HEAD /metrics HTTP/1.1\r\n\r\n")
	if err != nil || !strings.HasPrefix(resp, "HTTP/1.1 200 OK\r\n") ||
		!strings.HasSuffix(resp, "\r\n\r\n") {
		t.Fatalf("HEAD: %q, %v", resp, err)
	}

	// HTTP/1.0 works too.
	resp, err = rawRequest(t, url, "GET /metrics HTTP/1.0\r\n\r\n")
	if err != nil || !strings.HasPrefix(resp, "HTTP/1.1 200 OK\r\n") ||
		!strings.Contains(resp, "\r\nConnection: close\r\n") {
		t.Fatalf("HTTP/1.0: %q, %v", resp[:min(len(resp), 200)], err)
	}
}

// TestServerUnreadBody verifies a request body we never read doesn't lose
// the response: closing w/ unread bytes sends a RST, which can discard the
// response before the client reads it.
func TestServerUnreadBody(t *testing.T) {
	url := newFakeHost(t).serve(1)
	body := strings.Repeat("a", 512<<10)
	for range 10 {
		resp, err := http.Post(url+"/metrics", "text/plain",
			strings.NewReader(body))
		if err != nil {
			t.Fatalf("POST: %v", err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Fatalf("POST: expected 405, got %d", resp.StatusCode)
		}
	}
}
