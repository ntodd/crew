// Package ctlproto is the JSON-lines protocol shared by crew-vzd's socket
// (vzd.sock) and each helper's socket (vms/<id>/ctl.sock): one JSON object
// per line each way, one response per request, many requests per
// connection.
package ctlproto

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"sync"
	"syscall"
	"time"

	"github.com/ntodd/crew/native/crew-vz/exitrec"
)

const (
	MaxLine     = 64 << 10
	MaxConns    = 64
	IdleTimeout = 5 * time.Minute
)

// Error codes.
const (
	ErrBadRequest      = "bad_request"
	ErrUnknownOp       = "unknown_op"
	ErrNotFound        = "not_found"
	ErrInvalidConfig   = "invalid_config"
	ErrAlreadyRunning  = "already_running"
	ErrAlreadyExited   = "already_exited"
	ErrAlreadyLaunched = "already_launched"
	ErrStartFailed     = "start_failed"
	ErrNotRunning      = "not_running"
	ErrCannotStop      = "cannot_request_stop"
	ErrInternal        = "internal"
)

// Request is one line from a client.
type Request struct {
	Op       string `json:"op"`
	VMID     string `json:"vm_id,omitempty"`
	Force    bool   `json:"force,omitempty"`
	Deadline int64  `json:"deadline,omitempty"` // unix seconds, for start
}

// Response is one line back.
type Response struct {
	OK     bool       `json:"ok"`
	Error  string     `json:"error,omitempty"`  // a code from this package
	Detail string     `json:"detail,omitempty"` // human-readable
	VM     *VMStatus  `json:"vm,omitempty"`
	VMs    []VMStatus `json:"vms,omitempty"`
}

// VMStatus describes one VM.
type VMStatus struct {
	VMID         string          `json:"vm_id"`
	State        string          `json:"state"`
	PID          int             `json:"pid,omitempty"`
	StartedAt    string          `json:"started_at,omitempty"`
	UptimeS      float64         `json:"uptime_s,omitempty"`
	Deadline     int64           `json:"deadline,omitempty"`
	ConsoleBytes int64           `json:"console_bytes,omitempty"`
	Net          json.RawMessage `json:"net,omitempty"`
	Exited       *exitrec.Record `json:"exited,omitempty"`
}

// Fail builds an error response.
func Fail(code, format string, args ...any) Response {
	return Response{Error: code, Detail: fmt.Sprintf(format, args...)}
}

// Handler answers one request.
type Handler func(ctx context.Context, r Request) Response

// Listen binds a Unix socket at path with the given mode. A stale socket
// (one nobody answers on) is replaced; a live one or any other kind of file
// is an error.
func Listen(path string, mode os.FileMode) (net.Listener, error) {
	if st, err := os.Lstat(path); err == nil {
		if st.Mode()&os.ModeSocket == 0 {
			return nil, fmt.Errorf("%s exists and is not a socket", path)
		}
		if c, err := net.DialTimeout("unix", path, time.Second); err == nil {
			c.Close()
			return nil, fmt.Errorf("%s: already being served", path)
		}
		if err := os.Remove(path); err != nil {
			return nil, err
		}
	}
	// Bind with a umask that leaves the socket no wider than mode, then
	// set mode exactly.
	old := syscall.Umask(0o777 &^ int(mode.Perm()))
	ln, err := net.Listen("unix", path)
	syscall.Umask(old)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, mode.Perm()); err != nil {
		ln.Close()
		return nil, err
	}
	return ln, nil
}

// Serve answers connections on ln until ctx is done or ln is closed.
func Serve(ctx context.Context, ln net.Listener, h Handler) error {
	go func() {
		<-ctx.Done()
		ln.Close()
	}()
	sem := make(chan struct{}, MaxConns)
	var wg sync.WaitGroup
	defer wg.Wait()
	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			return err
		}
		select {
		case sem <- struct{}{}:
		default:
			c.Close() // too many clients
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() { <-sem }()
			serveConn(ctx, c, h)
		}()
	}
}

func serveConn(ctx context.Context, c net.Conn, h Handler) {
	defer c.Close()
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()
	sc := bufio.NewScanner(c)
	sc.Buffer(make([]byte, 4096), MaxLine)
	enc := json.NewEncoder(c)
	for {
		c.SetReadDeadline(time.Now().Add(IdleTimeout))
		if !sc.Scan() {
			if errors.Is(sc.Err(), bufio.ErrTooLong) {
				c.SetWriteDeadline(time.Now().Add(time.Second))
				enc.Encode(Fail(ErrBadRequest, "line longer than %d bytes", MaxLine))
			}
			return
		}
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		var resp Response
		var req Request
		dec := json.NewDecoder(bytes.NewReader(line))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&req); err != nil {
			resp = Fail(ErrBadRequest, "%v", err)
		} else if req.Op == "" {
			resp = Fail(ErrBadRequest, "missing op")
		} else {
			resp = h(ctx, req)
		}
		c.SetWriteDeadline(time.Now().Add(10 * time.Second))
		if err := enc.Encode(resp); err != nil {
			return
		}
	}
}

// Call sends one request to the socket at path and reads the response.
func Call(ctx context.Context, path string, req Request) (Response, error) {
	var d net.Dialer
	c, err := d.DialContext(ctx, "unix", path)
	if err != nil {
		return Response{}, err
	}
	defer c.Close()
	if dl, ok := ctx.Deadline(); ok {
		c.SetDeadline(dl)
	}
	stop := context.AfterFunc(ctx, func() { c.SetDeadline(time.Now()) })
	defer stop()
	if err := json.NewEncoder(c).Encode(req); err != nil {
		return Response{}, err
	}
	sc := bufio.NewScanner(c)
	sc.Buffer(make([]byte, 4096), MaxLine*4)
	if !sc.Scan() {
		if err := sc.Err(); err != nil {
			return Response{}, err
		}
		return Response{}, errors.New("connection closed without a response")
	}
	var resp Response
	if err := json.Unmarshal(sc.Bytes(), &resp); err != nil {
		return Response{}, fmt.Errorf("bad response: %w", err)
	}
	return resp, nil
}
