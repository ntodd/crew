package vmctl

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"time"
)

// Each VMM gets its lease identity, a private view of /srv/crew, and only
// its checked kernel and clone. Only the root post-stop recorder can
// create files in the job directory.
func cloudUnit(vm VM, p Paths, now time.Time) []string {
	dir := p.Chroot(vm.ID)
	args := []string{"systemd-run", "--unit=crew-vm-" + vm.ID, "--collect", "--slice=crew-jobs.slice"}
	for _, prop := range []string{
		"Type=notify",
		"NotifyAccess=main",
		"TimeoutStartSec=30",
		"TimeoutStopSec=5",
		"KillMode=control-group",
		"MemoryMax=" + strconv.Itoa(BootMiB(vm.MemoryMiB)+256) + "M",
		"MemorySwapMax=0",
		"CPUQuota=" + strconv.Itoa(vm.VCPUs*100) + "%",
		"RuntimeMaxSec=" + strconv.FormatInt(max(1, int64(vm.Deadline.Sub(now)/time.Second)), 10),
		"TasksMax=1024",
		"NoNewPrivileges=yes",
		"CapabilityBoundingSet=CAP_SETUID CAP_SETGID CAP_SETPCAP",
		"PrivateTmp=yes",
		"ProtectSystem=strict",
		"ProtectHome=yes",
		"ProtectControlGroups=yes",
		"ProtectKernelModules=yes",
		"ProtectKernelTunables=yes",
		"UMask=0077",
		"DevicePolicy=closed",
		"DeviceAllow=/dev/kvm rw",
		"DeviceAllow=/dev/net/tun rw",
		"TemporaryFileSystem=" + p.Data + ":ro /run:ro",
		"BindReadOnlyPaths=" + p.Vmctl() + " " + p.bin("cloud-hypervisor") + " " + dir + " -/run/systemd/notify",
		"BindPaths=" + p.JailDir(vm.ID) + " " + filepath.Join(dir, "rootfs.ext4"),
		"RestrictAddressFamilies=AF_UNIX",
		"RestrictNamespaces=yes",
		"ProtectProc=invisible",
		"StandardOutput=append:" + p.Console(vm.ID),
		"StandardError=append:" + p.Stderr(vm.ID),
		"ExecStopPost=" + p.Vmctl() + " exited " + vm.ID,
	} {
		args = append(args, "-p", prop)
	}
	// systemd requires User= to resolve through NSS. Lease IDs deliberately
	// have no passwd entries. Drop all capabilities before any job code runs.
	return append(args, "--", "/usr/bin/setpriv", "--reuid="+strconv.Itoa(vm.Lease.UID),
		"--regid="+strconv.Itoa(vm.Lease.GID), "--groups=kvm", "--bounding-set=-all",
		"--inh-caps=-all", "--ambient-caps=-all", p.Vmctl(), "cloud-run", vm.ID)
}

func cloudConfig(c fcConfig, dir string) ([]byte, error) {
	if len(c.Drives) != 1 || len(c.NetworkInterfaces) != 1 {
		return nil, fmt.Errorf("expected one job disk and one network interface")
	}
	iface := c.NetworkInterfaces[0]
	if !reflect.DeepEqual(iface.RxRateLimiter, iface.TxRateLimiter) {
		return nil, fmt.Errorf("Cloud Hypervisor requires matching receive and transmit limits")
	}
	if c.Entropy != nil && c.Entropy.RateLimiter != nil {
		return nil, fmt.Errorf("Cloud Hypervisor does not support an entropy rate limit")
	}
	disk := map[string]any{"path": filepath.Join(dir, "rootfs.ext4"), "image_type": "Raw", "rate_limiter_config": c.Drives[0].RateLimiter}
	nic := map[string]any{"tap": iface.HostDevName, "mac": iface.GuestMAC, "rate_limiter_config": iface.TxRateLimiter}
	return json.Marshal(map[string]any{
		"payload": map[string]any{"kernel": filepath.Join(dir, "kernel"), "cmdline": c.BootSource.BootArgs},
		"cpus":    map[string]int{"boot_vcpus": c.MachineConfig.VCPUCount, "max_vcpus": c.MachineConfig.VCPUCount},
		// Concurrent short-lived jobs can stall on host compaction when the VMM requests huge pages.
		"memory":          map[string]any{"size": int64(c.MachineConfig.MemSizeMiB) << 20, "thp": false},
		"landlock_enable": true,
		"landlock_rules":  []map[string]string{{"path": filepath.Join("/sys/class/net", iface.HostDevName, "tun_flags"), "access": "r"}},
		"disks":           []any{disk},
		"net":             []any{nic},
		"serial":          map[string]string{"mode": "File", "file": filepath.Join(filepath.Dir(dir), "console.log")},
		"console":         map[string]string{"mode": "Off"},
	})
}

// RunCloud runs as the job's uid. Pass the guest token in a private API
// request so it never appears in ps, the unit properties or journald.
func RunCloud(p Paths, id, notify string) error {
	dir := p.Chroot(id)
	data, err := os.ReadFile(filepath.Join(dir, "fc.json"))
	if err != nil {
		return err
	}
	var cfg fcConfig
	if err = json.Unmarshal(data, &cfg); err != nil {
		return err
	}
	body, err := cloudConfig(cfg, dir)
	if err != nil {
		return err
	}
	tmp, err := os.MkdirTemp("", "crew-vmm-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	addr := filepath.Join(tmp, "api")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: addr, Net: "unix"})
	if err != nil {
		return err
	}
	defer listener.Close()
	fd, err := listener.File()
	if err != nil {
		return err
	}

	cmd := exec.Command(p.bin("cloud-hypervisor"), "--api-socket", "fd=3")
	cmd.ExtraFiles = []*os.File{fd}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		fd.Close()
		return err
	}
	defer func() {
		if cmd.ProcessState == nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
	}()
	fd.Close()
	listener.SetUnlinkOnClose(false)
	listener.Close()
	client := http.Client{Timeout: 12 * time.Second, Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		var dialer net.Dialer
		return dialer.DialContext(ctx, "unix", addr)
	}}}
	defer client.CloseIdleConnections()
	for _, action := range []string{"vm.create", "vm.boot"} {
		req, err := http.NewRequest("PUT", "http://localhost/api/v1/"+action, bytes.NewReader(body))
		if err != nil {
			return err
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		resp.Body.Close()
		if resp.StatusCode/100 != 2 {
			return fmt.Errorf("Cloud Hypervisor %s: %s", action, resp.Status)
		}
		body = nil
	}
	if err := os.Remove(addr); err != nil {
		return err
	}
	socket, err := net.Dial("unixgram", notify)
	if err != nil {
		return err
	}
	_, err = socket.Write([]byte("READY=1"))
	socket.Close()
	if err != nil {
		return err
	}
	return cmd.Wait()
}
