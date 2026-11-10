// A minimal HTTP/1.1 server for `GET /metrics`, instead of net/http:
// net/http also links crypto/tls, x509, and HTTP/2, which tripled the binary
// size (5.9 MB vs 2.1 MB). Our only client is the local scraper.
//
// One request per connection: read the request line, skip the headers,
// write the response w/ `Content-Length` + `Connection: close`, close.
// Request bodies are never read. Each connection gets `connTimeout` and at
// most `maxRequestBytes` of request.
//
// After a response, closing w/ request bytes still unread (ex: a POST body)
// would send a RST, which can discard the response before the client reads
// it. So shut down our side first, then drain the client's leftovers until
// it closes too.
package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"time"
)

const (
	// deadline for one connection: read the request, write the response,
	// drain.
	connTimeout = 10 * time.Second

	// max request line + headers. Longer requests get the connection
	// closed.
	maxRequestBytes = 64 << 10

	// max leftover request bytes drained after a response. Past this, the
	// client may see a RST instead of the response.
	maxDrainBytes = 1 << 20
)

// errBadRequest is a malformed request line.
var errBadRequest = errors.New("bad request line")

// response is one HTTP response.
type response struct {
	status int
	// extra header lines, each ending in `\r\n`.
	header string
	body   []byte
}

// statusText are the reason phrases of the statuses we send.
var statusText = map[int]string{
	200: "OK",
	400: "Bad Request",
	404: "Not Found",
	405: "Method Not Allowed",
	500: "Internal Server Error",
}

// metricsServer answers HTTP requests for /metrics.
type metricsServer struct {
	hostPaths paths
	boots     uint64
	// per connection, see `connTimeout`. Tests shorten it.
	timeout time.Duration
}

// serve answers HTTP requests on `listener` until it fails or closes.
func (server *metricsServer) serve(listener net.Listener) error {
	for {
		conn, err := listener.Accept()
		if err != nil {
			return err
		}
		go server.serveConn(conn)
	}
}

// serveConn answers one request, then closes the connection.
func (server *metricsServer) serveConn(conn net.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(server.timeout))

	request := bufio.NewReader(io.LimitReader(conn, maxRequestBytes))
	method, path, err := readRequest(request)
	var resp response
	switch {
	case errors.Is(err, errBadRequest):
		resp = errorResponse(400, err)
	case err != nil:
		// Timeout, EOF, or too long: nothing useful to answer.
		return
	default:
		resp = handle(method, path, server.hostPaths, server.boots)
	}
	writeResponse(conn, method, resp)

	// Graceful close, see the file comment: FIN, then drain until the
	// client's EOF, the deadline, or `maxDrainBytes`. Not io.Copy: its
	// ReaderFrom/WriterTo checks link net's splice + sendfile code (+65 KB).
	if tcp, ok := conn.(interface{ CloseWrite() error }); ok {
		_ = tcp.CloseWrite()
	}
	drain := make([]byte, 4096)
	for drained := 0; drained < maxDrainBytes; {
		count, err := conn.Read(drain)
		if err != nil {
			return
		}
		drained += count
	}
}

// readRequest parses the request line, then skips the headers.
func readRequest(request *bufio.Reader) (method, path string, err error) {
	line, err := request.ReadSlice('\n')
	if err != nil {
		return "", "", err
	}

	// `<method> <target> HTTP/1.x`
	fields := strings.Fields(string(line))
	if len(fields) != 3 || !strings.HasPrefix(fields[2], "HTTP/1.") {
		return "", "", errBadRequest
	}
	method = fields[0]
	path, _, _ = strings.Cut(fields[1], "?")

	// Headers end at an empty line.
	for {
		header, err := request.ReadSlice('\n')
		if err != nil {
			return "", "", err
		}
		if len(bytes.TrimRight(header, "\r\n")) == 0 {
			return method, path, nil
		}
	}
}

// handle serves GET/HEAD /metrics.
func handle(method, path string, hostPaths paths, boots uint64) response {
	if path != "/metrics" {
		return errorResponse(404, errors.New("not found"))
	}
	if method != "GET" && method != "HEAD" {
		resp := errorResponse(405, errors.New("method not allowed"))
		resp.header += "Allow: GET, HEAD\r\n"
		return resp
	}

	body, err := renderMetrics(hostPaths, boots)
	if err != nil {
		// Fail the whole scrape: `up` goes 0, which is alertable, vs a
		// silently missing series.
		log.Printf("scrape: %v", err)
		return errorResponse(500, err)
	}
	return response{
		status: 200,
		header: "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n",
		body:   body,
	}
}

// errorResponse is a plain-text error.
func errorResponse(status int, err error) response {
	return response{
		status: status,
		header: "Content-Type: text/plain; charset=utf-8\r\n",
		body:   []byte(err.Error() + "\n"),
	}
}

// writeResponse writes the status line, headers, and (except for HEAD) the
// body in one writev.
func writeResponse(conn net.Conn, method string, resp response) {
	var head bytes.Buffer
	fmt.Fprintf(&head, "HTTP/1.1 %d %s\r\n%sContent-Length: %d\r\n"+
		"Connection: close\r\n\r\n",
		resp.status, statusText[resp.status], resp.header, len(resp.body))

	buffers := net.Buffers{head.Bytes()}
	if method != "HEAD" {
		buffers = append(buffers, resp.body)
	}
	_, _ = buffers.WriteTo(conn)
}
