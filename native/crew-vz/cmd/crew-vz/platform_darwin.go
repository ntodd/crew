//go:build darwin

package main

import (
	"github.com/ntodd/crew/native/crew-vz/config"
	"github.com/ntodd/crew/native/crew-vz/helper"
	"github.com/ntodd/crew/native/crew-vz/vm"
	"golang.org/x/sys/unix"
)

func newMachine(s helper.MachineSpec) (helper.Machine, error) { return vm.New(s) }

// platformLimits is what VZ allows, capped by the Mac: at most its
// physical cores, and its memory less 2 GiB.
func platformLimits() config.Limits {
	l := vm.Limits()
	if cores, err := unix.SysctlUint32("hw.physicalcpu"); err == nil && int(cores) < l.MaxVCPUs {
		l.MaxVCPUs = int(cores)
	}
	if mem, err := unix.SysctlUint64("hw.memsize"); err == nil {
		if host := int(mem>>20) - 2048; host < l.MaxMemoryMiB {
			l.MaxMemoryMiB = host
		}
	}
	return l
}
