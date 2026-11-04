// Package exitrec reads and writes exited.json, the record a VM's helper
// leaves when it's done: {"code", "reason", "at"} plus an optional
// "detail". Its presence means the VM's disk has been used, so a helper
// never starts a VM whose exited.json exists, and the first record written
// is never replaced.
package exitrec

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// Exit codes of crew-vz run (§11.4).
const (
	CodeClean    = 0 // the guest powered itself off
	CodeError    = 1
	CodeKilled   = 2 // stopped with force, or the helper was signalled
	CodeDeadline = 3
)

// Reasons.
const (
	ReasonGuestStopped = "guest_stopped"
	ReasonError        = "error"
	ReasonKilled       = "killed"
	ReasonDeadline     = "deadline"
	// ReasonHelperDied is written by crew-vzd when a helper vanished without
	// leaving a record (killed by a signal it couldn't catch, or crashed).
	ReasonHelperDied = "helper_died"
)

// ErrExists is returned by Write when a record is already present.
// FileName is the record's name in the VM's directory. It's fixed, so
// crew-vzd finds it even after the agent removes vz.json, and it never
// collides with the agent's own exited.json.
const FileName = "vz-exited.json"

var ErrExists = errors.New("the exit record already exists")

// Record is exited.json.
type Record struct {
	Code   int
	Reason string
	At     time.Time
	Detail string
}

type wire struct {
	Code   int    `json:"code"`
	Reason string `json:"reason"`
	At     string `json:"at"`
	Detail string `json:"detail,omitempty"`
}

const timeFormat = "2006-01-02T15:04:05.000Z07:00"

func (r Record) MarshalJSON() ([]byte, error) {
	return json.Marshal(wire{Code: r.Code, Reason: r.Reason, At: r.At.UTC().Format(timeFormat), Detail: r.Detail})
}

func (r *Record) UnmarshalJSON(b []byte) error {
	var w wire
	if err := json.Unmarshal(b, &w); err != nil {
		return err
	}
	at, err := time.Parse(time.RFC3339Nano, w.At)
	if err != nil {
		return fmt.Errorf("exited.json at: %w", err)
	}
	*r = Record{Code: w.Code, Reason: w.Reason, At: at, Detail: w.Detail}
	return nil
}

// Exists reports whether anything (even a dangling symlink) is at path.
func Exists(path string) (bool, error) {
	_, err := os.Lstat(path)
	if err == nil {
		return true, nil
	}
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	return false, err
}

// Write publishes r at path atomically, and only if nothing is there yet:
// the record goes to a temp file which is then hard-linked into place, and
// link(2) fails if path exists.
func Write(path string, r Record) error {
	if ok, err := Exists(path); err != nil {
		return err
	} else if ok {
		return ErrExists
	}
	data, err := json.Marshal(r)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	var suffix [6]byte
	rand.Read(suffix[:])
	tmp := filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+".tmp-"+hex.EncodeToString(suffix[:]))
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o640)
	if err != nil {
		return err
	}
	defer os.Remove(tmp)
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Link(tmp, path); err != nil {
		if errors.Is(err, fs.ErrExist) {
			return ErrExists
		}
		return err
	}
	return nil
}

// Read parses exited.json without following symlinks.
func Read(path string) (Record, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return Record{}, err
	}
	defer f.Close()
	var r Record
	dec := json.NewDecoder(f)
	if err := dec.Decode(&r); err != nil {
		return Record{}, fmt.Errorf("%s: %w", path, err)
	}
	return r, nil
}
