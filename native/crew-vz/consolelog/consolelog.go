// Package consolelog writes a guest console to a file with a hard size cap
// (§11.3): up to HeadMax+TailMax bytes the file is verbatim; past that it
// keeps the first HeadMax bytes, a fixed-width truncation marker, and a
// rolling tail, so the file is never larger than HeadMax+TailMax.
package consolelog

import (
	"errors"
	"fmt"
	"os"
	"sync"
	"syscall"
	"time"
)

const (
	DefaultHeadMax       = 4 << 20
	DefaultTailMax       = 4 << 20
	DefaultFlushInterval = time.Second
)

// Options sets the cap. Zero values take the defaults.
type Options struct {
	HeadMax       int64
	TailMax       int64
	FlushInterval time.Duration // how often a truncated tail is rewritten
}

// Marker is the line written between the head and the tail once the
// console has been truncated. Its width doesn't depend on omitted.
func Marker(omitted int64) []byte {
	return fmt.Appendf(nil, "\n[crew-vz: console truncated, %020d bytes omitted]\n", omitted)
}

var markerLen = int64(len(Marker(0)))

// Writer is safe for concurrent use.
type Writer struct {
	mu      sync.Mutex
	f       *os.File
	opts    Options
	written int64 // bytes of console stream seen

	// ring holds the last len(ring) bytes of the stream past HeadMax.
	ring   []byte
	rstart int
	rlen   int

	dirty     bool
	lastFlush time.Time
	err       error
}

// Open creates (or truncates) path. It never follows a symlink.
func Open(path string, o Options) (*Writer, error) {
	if o.HeadMax == 0 {
		o.HeadMax = DefaultHeadMax
	}
	if o.TailMax == 0 {
		o.TailMax = DefaultTailMax
	}
	if o.FlushInterval == 0 {
		o.FlushInterval = DefaultFlushInterval
	}
	if o.HeadMax < 0 || o.TailMax <= markerLen {
		return nil, fmt.Errorf("consolelog: tail (%d) must be larger than the %d-byte marker", o.TailMax, markerLen)
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC|syscall.O_NOFOLLOW, 0o640)
	if err != nil {
		return nil, err
	}
	return &Writer{
		f:         f,
		opts:      o,
		ring:      make([]byte, o.TailMax-markerLen),
		lastFlush: time.Now(),
	}, nil
}

func (w *Writer) limit() int64 { return w.opts.HeadMax + w.opts.TailMax }

// Write never returns a short count: once the cap is reached, bytes are
// kept in memory and the file's tail is rewritten at most every
// FlushInterval (and on Flush and Close).
func (w *Writer) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.err != nil {
		return 0, w.err
	}
	n := len(p)
	// Verbatim part, while the file is under the cap.
	if w.written < w.limit() {
		k := min(int64(len(p)), w.limit()-w.written)
		if _, err := w.f.WriteAt(p[:k], w.written); err != nil {
			w.err = err
			return 0, err
		}
		// Bytes past the head also go to the ring, in case they end up in
		// the tail.
		if past := w.written + k - w.opts.HeadMax; past > 0 {
			w.appendRing(p[k-min(past, k) : k])
		}
		w.written += k
		p = p[k:]
	}
	if len(p) > 0 {
		w.appendRing(p)
		w.written += int64(len(p))
		w.dirty = true
	}
	if w.dirty && time.Since(w.lastFlush) >= w.opts.FlushInterval {
		if err := w.flushLocked(); err != nil {
			return 0, err
		}
	}
	return n, nil
}

func (w *Writer) appendRing(p []byte) {
	c := len(w.ring)
	if len(p) >= c {
		copy(w.ring, p[len(p)-c:])
		w.rstart, w.rlen = 0, c
		return
	}
	end := (w.rstart + w.rlen) % c
	k := copy(w.ring[end:], p)
	copy(w.ring, p[k:])
	w.rlen += len(p)
	if w.rlen > c {
		w.rstart = (w.rstart + w.rlen - c) % c
		w.rlen = c
	}
}

// Flush rewrites the marker and tail if the stream has passed the cap.
func (w *Writer) Flush() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.flushLocked()
}

func (w *Writer) flushLocked() error {
	if w.err != nil {
		return w.err
	}
	w.lastFlush = time.Now()
	if !w.dirty {
		return nil
	}
	omitted := w.written - w.opts.HeadMax - int64(w.rlen)
	buf := make([]byte, 0, markerLen+int64(w.rlen))
	buf = append(buf, Marker(omitted)...)
	c := len(w.ring)
	first := min(w.rlen, c-w.rstart)
	buf = append(buf, w.ring[w.rstart:w.rstart+first]...)
	buf = append(buf, w.ring[:w.rlen-first]...)
	if _, err := w.f.WriteAt(buf, w.opts.HeadMax); err != nil {
		w.err = err
		return err
	}
	w.dirty = false
	return nil
}

// Close flushes and closes the file.
func (w *Writer) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	ferr := w.flushLocked()
	cerr := w.f.Close()
	if w.err == nil {
		w.err = errors.New("consolelog: closed")
	}
	if ferr != nil {
		return ferr
	}
	return cerr
}

// Written is the number of console bytes seen, truncated or not.
func (w *Writer) Written() int64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.written
}
