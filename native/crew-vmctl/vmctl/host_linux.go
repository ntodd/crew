//go:build linux

package vmctl

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"

	"github.com/ntodd/crew/native/crew-vmctl/ruleset"
)

// SafePath is the only PATH crew-vmctl and its children see.
const SafePath = "/usr/sbin:/usr/bin:/sbin:/bin"

// LinuxSys is the real host. Files under the data directory are opened
// with openat2(RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS) from the data
// directory itself, so nothing the agent puts in vms/ or images/ can
// lead crew-vmctl elsewhere.
type LinuxSys struct {
	Paths Paths
}

// NewSys is the host for p.
func NewSys(p Paths) Sys { return &LinuxSys{Paths: p} }

func (h *LinuxSys) Run(ctx context.Context, stdin []byte, argv ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Env = []string{"PATH=" + SafePath, "LC_ALL=C"}
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &limited{w: &stdout, n: 8 << 20}
	cmd.Stderr = &limited{w: &stderr, n: 8 << 10}
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = strings.TrimSpace(stdout.String())
		}
		return stdout.Bytes(), fmt.Errorf("%s: %v: %s", argv[0], err, clip(msg, 2000))
	}
	return stdout.Bytes(), nil
}

type limited struct {
	w io.Writer
	n int
}

func (l *limited) Write(p []byte) (int, error) {
	if l.n <= 0 {
		return len(p), nil
	}
	k := len(p)
	if k > l.n {
		k = l.n
	}
	l.n -= k
	_, err := l.w.Write(p[:k])
	return len(p), err
}

func clip(s string, n int) string {
	if len(s) > n {
		return s[:n] + "…"
	}
	return s
}

// beneath opens rel under the data directory, refusing symlinks on the
// way and at the end.
func (h *LinuxSys) beneath(rel string, flags int, mode uint32) (int, error) {
	dfd, err := unix.Open(h.Paths.Data, unix.O_DIRECTORY|unix.O_RDONLY|unix.O_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	defer unix.Close(dfd)
	return beneathAt(dfd, rel, flags, mode)
}

func beneathAt(dfd int, rel string, flags int, mode uint32) (int, error) {
	how := &unix.OpenHow{
		Flags:   uint64(flags | unix.O_CLOEXEC | unix.O_NOFOLLOW),
		Mode:    uint64(mode),
		Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS | unix.RESOLVE_NO_MAGICLINKS,
	}
	for {
		fd, err := unix.Openat2(dfd, rel, how)
		if err == unix.EINTR || err == unix.EAGAIN {
			continue
		}
		return fd, err
	}
}

func readFD(fd int, max int64) ([]byte, error) {
	f := os.NewFile(uintptr(fd), "")
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() {
		return nil, fmt.Errorf("not a regular file")
	}
	b, err := io.ReadAll(io.LimitReader(f, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > max {
		return nil, fmt.Errorf("over %d bytes", max)
	}
	return b, nil
}

func (h *LinuxSys) ReadAgentFile(vmID, name string) ([]byte, error) {
	if !IsUUID(vmID) || strings.ContainsAny(name, "/") {
		return nil, fmt.Errorf("bad path")
	}
	fd, err := h.beneath(filepath.Join("vms", vmID, name), unix.O_RDONLY, 0)
	if err != nil {
		return nil, err
	}
	return readFD(fd, MaxFile)
}

func (h *LinuxSys) ReadFile(path string, max int64) ([]byte, error) {
	if rel, ok := h.under(path); ok {
		fd, err := h.beneath(rel, unix.O_RDONLY, 0)
		if err != nil {
			return nil, err
		}
		return readFD(fd, max)
	}
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	return readFD(fd, max)
}

func (h *LinuxSys) under(path string) (string, bool) {
	rel, err := filepath.Rel(h.Paths.Data, path)
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") {
		return "", false
	}
	return rel, true
}

func (h *LinuxSys) WriteFile(path string, data []byte) error {
	if _, ok := h.under(path); ok {
		return fmt.Errorf("%s: crew-vmctl doesn't write the data directory this way", path)
	}
	if strings.HasPrefix(path, "/run/") {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC|syscall.O_NOFOLLOW, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// CreateFile creates path exclusively (an exit record in the jail).
func (h *LinuxSys) CreateFile(path string, data []byte) error {
	rel, ok := h.under(path)
	if !ok {
		return fmt.Errorf("%s isn't in the data directory", path)
	}
	fd, err := h.beneath(rel, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL, 0o644)
	if err != nil {
		if errors.Is(err, unix.EEXIST) {
			return os.ErrExist
		}
		return err
	}
	f := os.NewFile(uintptr(fd), path)
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// WriteState writes <data>/vmctl/<name> through a temporary file and a
// rename, in a directory only root can change.
func (h *LinuxSys) WriteState(name string, data []byte) error {
	if strings.ContainsAny(name, "/") || name == "" || strings.HasPrefix(name, ".") {
		return fmt.Errorf("state %q: not a file name", name)
	}
	dfd, err := unix.Open(h.Paths.Data, unix.O_DIRECTORY|unix.O_RDONLY|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	defer unix.Close(dfd)
	sfd, err := rootDir(dfd, StateDir)
	if err != nil {
		return err
	}
	defer unix.Close(sfd)
	tmp := "." + name + ".tmp"
	_ = unix.Unlinkat(sfd, tmp, 0)
	if err := createAt(sfd, tmp, 0o644, data, 0, 0); err != nil {
		return err
	}
	return unix.Renameat(sfd, tmp, sfd, name)
}

func (h *LinuxSys) Exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func (h *LinuxSys) Glob(pattern string) []string {
	m, _ := filepath.Glob(pattern)
	return m
}

// rootDir makes (or opens) a directory that only root can change, under
// dfd. One the agent could write to is refused.
func rootDir(dfd int, name string) (int, error) {
	if err := unix.Mkdirat(dfd, name, 0o755); err != nil && !errors.Is(err, unix.EEXIST) {
		return -1, err
	}
	fd, err := beneathAt(dfd, name, unix.O_DIRECTORY|unix.O_RDONLY, 0)
	if err != nil {
		return -1, err
	}
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil {
		unix.Close(fd)
		return -1, err
	}
	if st.Uid != 0 || st.Mode&0o022 != 0 {
		unix.Close(fd)
		return -1, fmt.Errorf("%s must be root's and not group- or world-writable", name)
	}
	return fd, nil
}

func createAt(dfd int, name string, mode uint32, data []byte, uid, gid int) error {
	fd, err := beneathAt(dfd, name, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL, mode)
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	f := os.NewFile(uintptr(fd), name)
	defer f.Close()
	if err := unix.Fchown(fd, uid, gid); err != nil {
		return err
	}
	if err := unix.Fchmod(fd, mode); err != nil {
		return err
	}
	_, err = f.Write(data)
	return err
}

// PrepareJail lays out jail/firecracker/<vm_id>/ (README.md): the chroot
// with hard links to the clone (given to the VM's uid, 0600) and the
// kernel, the checked fc.json and the VMM's log files; beside it the
// lease and the console and stderr files systemd appends to, owned by
// the agent so it can cap the console.
func (h *LinuxSys) PrepareJail(j Jail) (err error) {
	vm, uid, gid := j.VM, j.VM.Lease.UID, j.VM.Lease.GID
	dfd, err := unix.Open(h.Paths.Data, unix.O_DIRECTORY|unix.O_RDONLY|unix.O_CLOEXEC, 0)
	if err != nil {
		return err
	}
	defer unix.Close(dfd)
	jfd, err := rootDir(dfd, "jail")
	if err != nil {
		return err
	}
	defer unix.Close(jfd)
	ffd, err := rootDir(jfd, "firecracker")
	if err != nil {
		return err
	}
	defer unix.Close(ffd)
	if err := unix.Mkdirat(ffd, vm.ID, 0o755); err != nil {
		if errors.Is(err, unix.EEXIST) {
			return fail(ErrAlreadyLaunch, "%s exists: a VM is launched once", h.Paths.JailDir(vm.ID))
		}
		return err
	}
	defer func() {
		if err != nil {
			_ = os.RemoveAll(h.Paths.JailDir(vm.ID))
		}
	}()
	vfd, err := rootDir(ffd, vm.ID)
	if err != nil {
		return err
	}
	defer unix.Close(vfd)
	cfd, err := rootDir(vfd, "root")
	if err != nil {
		return err
	}
	defer unix.Close(cfd)
	var jst unix.Stat_t
	if err := unix.Fstat(cfd, &jst); err != nil {
		return err
	}

	if err := createAt(vfd, "lease", 0o644, []byte(strconv.Itoa(vm.Lease.Index)+"\n"), 0, 0); err != nil {
		return err
	}
	for _, name := range []string{"console.log", "fc.stderr"} {
		if err := createAt(vfd, name, 0o640, nil, j.Owner.UID, j.Owner.GID); err != nil {
			return err
		}
	}

	// The clone: the agent's, a regular file with no other links, on the
	// jail's filesystem. It becomes the VM's.
	clone, err := beneathAt(dfd, filepath.Join("vms", vm.ID, "rootfs.ext4"), unix.O_RDWR, 0)
	if err != nil {
		return fail(ErrInvalidConfig, "the clone: %v", err)
	}
	defer unix.Close(clone)
	if err := checkFile(clone, j.Owner.UID, jst.Dev, true); err != nil {
		return fail(ErrInvalidConfig, "the clone: %v", err)
	}
	if err := unix.Fchown(clone, uid, gid); err != nil {
		return err
	}
	if err := unix.Fchmod(clone, 0o600); err != nil {
		return err
	}
	if err := unix.Linkat(clone, "", cfd, "rootfs.ext4", unix.AT_EMPTY_PATH); err != nil {
		return fmt.Errorf("linking the clone into the jail: %w", err)
	}

	// The kernel: the agent's, read-only to everyone, shared by the
	// image's VMs.
	kernel, err := beneathAt(dfd, filepath.Join("images", vm.ImageID, "kernel"), unix.O_RDONLY, 0)
	if err != nil {
		return fail(ErrInvalidConfig, "the kernel: %v", err)
	}
	defer unix.Close(kernel)
	if err := checkFile(kernel, j.Owner.UID, jst.Dev, false); err != nil {
		return fail(ErrInvalidConfig, "the kernel: %v", err)
	}
	if err := unix.Linkat(kernel, "", cfd, "kernel", unix.AT_EMPTY_PATH); err != nil {
		return fmt.Errorf("linking the kernel into the jail: %w", err)
	}

	if err := createAt(cfd, "fc.json", 0o400, j.Config, uid, gid); err != nil {
		return err
	}
	for _, name := range []string{"fc.log", "fc.metrics"} {
		if err := createAt(cfd, name, 0o600, nil, uid, gid); err != nil {
			return err
		}
	}
	return nil
}

func checkFile(fd, owner int, dev uint64, clone bool) error {
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil {
		return err
	}
	switch {
	case st.Mode&unix.S_IFMT != unix.S_IFREG:
		return fmt.Errorf("not a regular file")
	case int(st.Uid) != owner:
		return fmt.Errorf("owned by uid %d, not the agent's %d", st.Uid, owner)
	case st.Dev != dev:
		return fmt.Errorf("not on the jail's filesystem")
	case clone && st.Nlink != 1:
		return fmt.Errorf("has %d links; a clone has one", st.Nlink)
	case !clone && st.Mode&0o022 != 0:
		return fmt.Errorf("is group- or world-writable")
	case !clone && st.Mode&0o004 == 0:
		return fmt.Errorf("isn't world-readable (the VM's uid reads it)")
	}
	return nil
}

// RemoveJail moves the console, stderr and the VMM's log into
// vms/<vm_id>/ (when it's still there), then removes the jail directory.
func (h *LinuxSys) RemoveJail(vmID string, owner Peer) error {
	dir := h.Paths.JailDir(vmID)
	if _, err := os.Lstat(dir); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if vfd, err := h.beneath(filepath.Join("vms", vmID), unix.O_DIRECTORY|unix.O_RDONLY, 0); err == nil {
		defer unix.Close(vfd)
		if jfd, err := unix.Open(dir, unix.O_DIRECTORY|unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0); err == nil {
			defer unix.Close(jfd)
			for _, name := range []string{"console.log", "fc.stderr"} {
				_ = unix.Renameat(jfd, name, vfd, name)
			}
			if fd, err := beneathAt(jfd, "root/fc.log", unix.O_RDONLY, 0); err == nil {
				var st unix.Stat_t
				if unix.Fstat(fd, &st) == nil && st.Mode&unix.S_IFMT == unix.S_IFREG && unix.Fchown(fd, owner.UID, owner.GID) == nil {
					_ = unix.Fchmod(fd, 0o640)
					_ = unix.Renameat(jfd, "root/fc.log", vfd, "fc.log")
				}
				unix.Close(fd)
			}
		}
	}
	return os.RemoveAll(dir)
}

// Reference runs `crew-vmctl nft-reference` in a new network namespace.
func (h *LinuxSys) Reference(uplink string) (ruleset.Listing, error) {
	cmd := exec.Command("/proc/self/exe", "nft-reference", "--uplink", uplink)
	cmd.Env = []string{"PATH=" + SafePath, "LC_ALL=C"}
	cmd.SysProcAttr = &syscall.SysProcAttr{Cloneflags: syscall.CLONE_NEWNET}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return ruleset.Listing{}, fmt.Errorf("%v: %s", err, clip(strings.TrimSpace(stderr.String()), 2000))
	}
	var out ReferenceOutput
	if err := json.Unmarshal(stdout.Bytes(), &out); err != nil {
		return ruleset.Listing{}, err
	}
	return ruleset.Listing{Nft: out.Nft, Mangle: out.Mangle}, nil
}

// PeerOf is the credentials of the process on the other end of the
// socket on fd.
func PeerOf(fd int) (Peer, error) {
	u, err := unix.GetsockoptUcred(fd, unix.SOL_SOCKET, unix.SO_PEERCRED)
	if err != nil {
		return Peer{}, err
	}
	return Peer{UID: int(u.Uid), GID: int(u.Gid)}, nil
}
