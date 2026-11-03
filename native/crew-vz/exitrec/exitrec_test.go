package exitrec

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWriteReadRoundTrip(t *testing.T) {
	p := filepath.Join(t.TempDir(), "exited.json")
	at := time.Date(2026, 11, 3, 15, 4, 5, 123_000_000, time.UTC)
	if err := Write(p, Record{Code: CodeDeadline, Reason: ReasonDeadline, At: at}); err != nil {
		t.Fatal(err)
	}
	got, err := Read(p)
	if err != nil {
		t.Fatal(err)
	}
	if got.Code != 3 || got.Reason != "deadline" || !got.At.Equal(at) {
		t.Fatalf("got %+v", got)
	}
	raw, _ := os.ReadFile(p)
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	if len(m) != 3 || m["code"] != float64(3) || m["reason"] != "deadline" || m["at"] != "2026-11-03T15:04:05.123Z" {
		t.Fatalf("wire format: %s", raw)
	}
}

func TestDetailIsOptional(t *testing.T) {
	p := filepath.Join(t.TempDir(), "exited.json")
	Write(p, Record{Code: CodeError, Reason: ReasonError, At: time.Now(), Detail: "boom"})
	raw, _ := os.ReadFile(p)
	var m map[string]any
	json.Unmarshal(raw, &m)
	if m["detail"] != "boom" {
		t.Fatalf("detail missing: %s", raw)
	}
}

func TestFirstWriterWins(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "exited.json")
	if err := Write(p, Record{Code: CodeClean, Reason: ReasonGuestStopped, At: time.Now()}); err != nil {
		t.Fatal(err)
	}
	err := Write(p, Record{Code: CodeKilled, Reason: ReasonKilled, At: time.Now()})
	if !errors.Is(err, ErrExists) {
		t.Fatalf("second write: %v, want ErrExists", err)
	}
	got, _ := Read(p)
	if got.Code != CodeClean {
		t.Fatalf("record overwritten: %+v", got)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 1 {
		t.Fatalf("leftover files: %v", entries)
	}
}

func TestExists(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "exited.json")
	if ok, err := Exists(p); ok || err != nil {
		t.Fatalf("Exists on empty dir: %v %v", ok, err)
	}
	// A dangling symlink still counts: nothing may be written through it.
	os.Symlink(filepath.Join(dir, "nowhere"), p)
	if ok, _ := Exists(p); !ok {
		t.Fatal("dangling symlink not seen")
	}
	if err := Write(p, Record{Code: 0, Reason: ReasonGuestStopped, At: time.Now()}); !errors.Is(err, ErrExists) {
		t.Fatalf("wrote through a symlink: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "nowhere")); !os.IsNotExist(err) {
		t.Fatal("symlink target created")
	}
}

func TestCodes(t *testing.T) {
	if CodeClean != 0 || CodeError != 1 || CodeKilled != 2 || CodeDeadline != 3 {
		t.Fatal("exit codes differ from §11.4")
	}
}
