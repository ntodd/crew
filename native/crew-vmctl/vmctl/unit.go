package vmctl

import (
	"strconv"
	"time"
)

// SystemdRunArgv is the transient unit `start` runs (§11.3). systemd owns
// every limit and the VMM is the unit's process tree, so jailer gets no
// --cgroup, --parent-cgroup, --daemonize or --new-pid-ns; with --no-api
// the whole configuration is the chroot's fc.json.
//
// Two differences from the spec's sketch (README.md):
//   - the console and stderr are appended to files in the VM's jail
//     directory, not vms/<vm_id>/: systemd opens them as root, and the
//     agent could have put a symlink at any path under its own directory;
//   - ExecStopPost runs `crew-vmctl exited`, which records how the VMM
//     ended before --collect forgets the unit.
func SystemdRunArgv(vm VM, p Paths, now time.Time) []string {
	left := int64(vm.Deadline.Sub(now) / time.Second)
	if left < 1 {
		left = 1
	}
	uid := strconv.Itoa(vm.Lease.UID)
	gid := strconv.Itoa(vm.Lease.GID)
	prop := func(kv string) []string { return []string{"-p", kv} }

	argv := []string{"systemd-run", "--unit=crew-vm-" + vm.ID, "--collect"}
	for _, kv := range []string{
		"Type=exec", "KillMode=mixed", "TimeoutStopSec=30",
		"MemoryMax=" + strconv.Itoa(vm.MemoryMiB+256) + "M", "MemorySwapMax=0", "TasksMax=1024",
		"CPUAccounting=yes", "RuntimeMaxSec=" + strconv.FormatInt(left, 10), "OOMScoreAdjust=500",
		"StandardOutput=append:" + p.Console(vm.ID),
		"StandardError=append:" + p.Stderr(vm.ID),
		"LogRateLimitIntervalSec=10", "LogRateLimitBurst=1000",
		"ExecStopPost=" + p.Vmctl() + " exited " + vm.ID,
	} {
		argv = append(argv, prop(kv)...)
	}
	return append(argv, "--",
		p.Jailer(),
		"--id", vm.ID, "--exec-file", p.Firecracker(),
		"--uid", uid, "--gid", gid, "--chroot-base-dir", p.JailBase(),
		"--", "--config-file", "/fc.json", "--no-api",
	)
}
