package vmctl

import (
	"reflect"
	"testing"
	"time"
)

func TestSystemdRunArgvIsTheSpecsUnit(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	vm, err := ParseVM(vmJSON(now.Unix()+3600), vmID, testNet(t), now)
	if err != nil {
		t.Fatal(err)
	}
	got := SystemdRunArgv(vm, paths, now)
	// §11.3, verbatim, but for where the console and stderr go (the jail's
	// directory, which the agent can't swap for a symlink) and the exit
	// record hook (README.md).
	jail := "/srv/crew/jail/firecracker/" + vmID
	want := []string{
		"systemd-run", "--unit=crew-vm-" + vmID, "--collect",
		"-p", "Type=exec", "-p", "KillMode=mixed", "-p", "TimeoutStopSec=30",
		"-p", "MemoryMax=8448M", "-p", "MemorySwapMax=0", "-p", "TasksMax=1024",
		"-p", "CPUAccounting=yes", "-p", "RuntimeMaxSec=3600", "-p", "OOMScoreAdjust=500",
		"-p", "StandardOutput=append:" + jail + "/console.log",
		"-p", "StandardError=append:" + jail + "/fc.stderr",
		"-p", "LogRateLimitIntervalSec=10", "-p", "LogRateLimitBurst=1000",
		"-p", "ExecStopPost=/srv/crew/agent/current/bin/crew-vmctl exited " + vmID,
		"--",
		"/srv/crew/agent/current/bin/jailer",
		"--id", vmID, "--exec-file", "/srv/crew/agent/current/bin/firecracker",
		"--uid", "200003", "--gid", "200003", "--chroot-base-dir", "/srv/crew/jail",
		"--", "--config-file", "/fc.json", "--no-api",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("argv:\n%q\nwant:\n%q", got, want)
	}
}

func TestRuntimeMaxSecCountsFromNow(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	vm, _ := ParseVM(vmJSON(now.Unix()+3600), vmID, testNet(t), now)
	later := now.Add(1000*time.Second + 500*time.Millisecond)
	for i, a := range SystemdRunArgv(vm, paths, later) {
		if a == "RuntimeMaxSec=2599" {
			return
		}
		_ = i
	}
	t.Fatal("RuntimeMaxSec should be the whole seconds left to the deadline")
}
