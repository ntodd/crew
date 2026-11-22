package vmctl

import (
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/sys/unix"
)

func TestReadOpensNonblocking(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "config"), []byte("example"), 0600); err != nil {
		t.Fatal(err)
	}
	h := &LinuxSys{Paths: Paths{Data: dir}}
	fd, err := h.beneath("config", unix.O_RDONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fd)
	flags, err := unix.FcntlInt(uintptr(fd), unix.F_GETFL, 0)
	if err != nil {
		t.Fatal(err)
	}
	if flags&unix.O_NONBLOCK == 0 {
		t.Fatal("opened without O_NONBLOCK")
	}
}
