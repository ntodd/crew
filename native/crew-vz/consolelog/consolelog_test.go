package consolelog

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	head = 64
	tail = 128
)

func open(t *testing.T) (*Writer, string) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "console.log")
	w, err := Open(p, Options{HeadMax: head, TailMax: tail})
	if err != nil {
		t.Fatal(err)
	}
	return w, p
}

func read(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// stream is a recognisable byte sequence so truncation can be checked.
func stream(n int) []byte {
	var b bytes.Buffer
	for i := 0; b.Len() < n; i++ {
		fmt.Fprintf(&b, "<%d>", i)
	}
	return b.Bytes()[:n]
}

func TestBelowCapIsVerbatim(t *testing.T) {
	w, p := open(t)
	s := stream(head + tail)
	for i := 0; i < len(s); i += 7 {
		end := min(i+7, len(s))
		if _, err := w.Write(s[i:end]); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	if got := read(t, p); !bytes.Equal(got, s) {
		t.Fatalf("got %q\nwant %q", got, s)
	}
}

func checkTruncated(t *testing.T, got, s []byte) {
	t.Helper()
	if len(got) != head+tail {
		t.Fatalf("file is %d bytes, want exactly %d", len(got), head+tail)
	}
	if !bytes.Equal(got[:head], s[:head]) {
		t.Fatal("head not preserved")
	}
	m := Marker(0)
	tailLen := tail - len(m)
	if !bytes.Equal(got[head+len(m):], s[len(s)-tailLen:]) {
		t.Fatalf("tail is %q, want %q", got[head+len(m):], s[len(s)-tailLen:])
	}
	marker := string(got[head : head+len(m)])
	omitted := len(s) - head - tailLen
	if marker != string(Marker(int64(omitted))) {
		t.Fatalf("marker %q, want %q", marker, Marker(int64(omitted)))
	}
}

func TestPastCapKeepsHeadAndRollingTail(t *testing.T) {
	for _, chunk := range []int{1, 5, 64, 200, 10_000} {
		t.Run(fmt.Sprintf("chunk%d", chunk), func(t *testing.T) {
			w, p := open(t)
			s := stream(10_000)
			for i := 0; i < len(s); i += chunk {
				end := min(i+chunk, len(s))
				if _, err := w.Write(s[i:end]); err != nil {
					t.Fatal(err)
				}
				st, err := os.Stat(p)
				if err != nil {
					t.Fatal(err)
				}
				if st.Size() > head+tail {
					t.Fatalf("file grew to %d bytes", st.Size())
				}
			}
			if err := w.Close(); err != nil {
				t.Fatal(err)
			}
			checkTruncated(t, read(t, p), s)
		})
	}
}

func TestFlushPublishesTail(t *testing.T) {
	w, p := open(t)
	defer w.Close()
	s := stream(1000)
	if _, err := w.Write(s); err != nil {
		t.Fatal(err)
	}
	if err := w.Flush(); err != nil {
		t.Fatal(err)
	}
	checkTruncated(t, read(t, p), s)
	more := stream(1500)
	if _, err := w.Write(more[1000:]); err != nil {
		t.Fatal(err)
	}
	if err := w.Flush(); err != nil {
		t.Fatal(err)
	}
	checkTruncated(t, read(t, p), more)
}

func TestMarkerIsFixedWidth(t *testing.T) {
	if len(Marker(0)) != len(Marker(1<<62)) {
		t.Fatal("marker width depends on the count")
	}
	if !strings.Contains(string(Marker(12345)), "12345") {
		t.Fatal("marker lacks the count")
	}
}

func TestDefaults(t *testing.T) {
	p := filepath.Join(t.TempDir(), "console.log")
	w, err := Open(p, Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	if w.opts.HeadMax != 4<<20 || w.opts.TailMax != 4<<20 {
		t.Fatalf("defaults %+v, want 4 MiB + 4 MiB", w.opts)
	}
}

func TestOpenTruncatesAndRefusesSymlinks(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "console.log")
	os.WriteFile(p, []byte("old boot"), 0o640)
	w, err := Open(p, Options{HeadMax: head, TailMax: tail})
	if err != nil {
		t.Fatal(err)
	}
	w.Write([]byte("new"))
	w.Close()
	if got := read(t, p); string(got) != "new" {
		t.Fatalf("got %q", got)
	}

	target := filepath.Join(dir, "target")
	os.WriteFile(target, []byte("precious"), 0o640)
	link := filepath.Join(dir, "link.log")
	os.Symlink(target, link)
	if _, err := Open(link, Options{HeadMax: head, TailMax: tail}); err == nil {
		t.Fatal("followed a symlink")
	}
	if got := read(t, target); string(got) != "precious" {
		t.Fatal("symlink target modified")
	}
}

func TestTailMustFitMarker(t *testing.T) {
	p := filepath.Join(t.TempDir(), "console.log")
	if _, err := Open(p, Options{HeadMax: 10, TailMax: 10}); err == nil {
		t.Fatal("accepted a tail smaller than the marker")
	}
}
