package ctlproto

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func sockPath(t *testing.T) string {
	t.Helper()
	d, err := os.MkdirTemp("/tmp", "cvzctl")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	return filepath.Join(d, "ctl.sock")
}

func serve(t *testing.T, h Handler) string {
	t.Helper()
	p := sockPath(t)
	ln, err := Listen(p, 0o660)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go Serve(ctx, ln, h)
	return p
}

func TestCallRoundTrip(t *testing.T) {
	p := serve(t, func(ctx context.Context, r Request) Response {
		if r.Op != "status" || r.VMID != "vm1" {
			return Fail(ErrBadRequest, "got %+v", r)
		}
		return Response{OK: true, VM: &VMStatus{VMID: r.VMID, State: "running", PID: 42}}
	})
	resp, err := Call(context.Background(), p, Request{Op: "status", VMID: "vm1"})
	if err != nil {
		t.Fatal(err)
	}
	if !resp.OK || resp.VM == nil || resp.VM.PID != 42 || resp.VM.State != "running" {
		t.Fatalf("resp = %+v", resp)
	}
}

func TestSocketMode(t *testing.T) {
	p := serve(t, func(ctx context.Context, r Request) Response { return Response{OK: true} })
	st, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o660 || st.Mode()&os.ModeSocket == 0 {
		t.Fatalf("mode = %v", st.Mode())
	}
}

func TestManyRequestsOneConnAndBadLines(t *testing.T) {
	p := serve(t, func(ctx context.Context, r Request) Response {
		return Response{OK: true, Detail: r.Op}
	})
	c, err := net.Dial("unix", p)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	rd := bufio.NewReader(c)
	send := func(line string) Response {
		t.Helper()
		if _, err := c.Write([]byte(line + "\n")); err != nil {
			t.Fatal(err)
		}
		l, err := rd.ReadBytes('\n')
		if err != nil {
			t.Fatal(err)
		}
		var r Response
		if err := json.Unmarshal(l, &r); err != nil {
			t.Fatalf("bad response %q: %v", l, err)
		}
		return r
	}
	if r := send(`{"op":"list"}`); !r.OK || r.Detail != "list" {
		t.Fatalf("list: %+v", r)
	}
	if r := send(`not json`); r.OK || r.Error != ErrBadRequest {
		t.Fatalf("garbage: %+v", r)
	}
	if r := send(`{"op":"list","evil":1}`); r.OK || r.Error != ErrBadRequest {
		t.Fatalf("unknown field: %+v", r)
	}
	if r := send(`{"op":""}`); r.OK || r.Error != ErrBadRequest {
		t.Fatalf("empty op: %+v", r)
	}
	if r := send(`{"op":"status","vm_id":"vm1"}`); !r.OK || r.Detail != "status" {
		t.Fatalf("status after errors: %+v", r)
	}
}

func TestOversizedLineClosesConn(t *testing.T) {
	p := serve(t, func(ctx context.Context, r Request) Response { return Response{OK: true} })
	c, err := net.Dial("unix", p)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	c.Write([]byte(`{"op":"` + strings.Repeat("a", MaxLine+10) + `"}` + "\n"))
	buf := make([]byte, 1024)
	n, _ := c.Read(buf)
	if n > 0 && !strings.Contains(string(buf[:n]), ErrBadRequest) {
		t.Fatalf("unexpected response %q", buf[:n])
	}
	if _, err := c.Read(buf); err == nil {
		t.Fatal("connection still open after an oversized line")
	}
}

func TestListenReplacesStaleSocket(t *testing.T) {
	p := sockPath(t)
	ln, err := Listen(p, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	// Simulate a crash: the file stays, nobody listens.
	ln.(*net.UnixListener).SetUnlinkOnClose(false)
	ln.Close()
	ln2, err := Listen(p, 0o600)
	if err != nil {
		t.Fatalf("stale socket not replaced: %v", err)
	}
	defer ln2.Close()
	// A live listener must not be stolen.
	if _, err := Listen(p, 0o600); err == nil {
		t.Fatal("took over a live socket")
	}
}

func TestListenRefusesNonSocket(t *testing.T) {
	p := sockPath(t)
	os.WriteFile(p, []byte("precious"), 0o600)
	if _, err := Listen(p, 0o600); err == nil {
		t.Fatal("replaced a regular file")
	}
}

func TestCallTimesOut(t *testing.T) {
	p := serve(t, func(ctx context.Context, r Request) Response {
		time.Sleep(2 * time.Second)
		return Response{OK: true}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	if _, err := Call(ctx, p, Request{Op: "status"}); err == nil {
		t.Fatal("expected timeout")
	}
}
