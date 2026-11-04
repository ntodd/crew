//go:build darwin

// Command hostvm-dev boots a Linux host VM on this Mac with Apple's
// Virtualization framework, for development: a Flatcar box with nested
// virtualization, where the Firecracker driver's real-KVM tests run
// (docs/architecture.md, "Firecracker driver notes"). Boxes themselves
// use vfkit (spec §12.3); this is the same binding (Code-Hex/vz) with only
// what a dev box needs, so it runs without downloading anything.
//
//	hostvm-dev -disk os.img [-disk data.img] [-iso cfg.iso] -serial serial.log \
//	    [-efi-vars efi-vars | -kernel vmlinuz -initrd empty.cpio -cmdline "..."] \
//	    [-cpus 4] [-memory 8192] [-nested] [-mac 52:54:00:..]
//
// It runs until the guest powers off; SIGTERM or SIGINT asks the guest
// to power off and waits up to 60 s.
package main

import (
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/Code-Hex/vz/v3"
)

type list []string

func (l *list) String() string     { return strings.Join(*l, ",") }
func (l *list) Set(v string) error { *l = append(*l, v); return nil }

func main() {
	var disks list
	flag.Var(&disks, "disk", "a read-write disk image (repeatable)")
	iso := flag.String("iso", "", "a read-only disk image (the Ignition ISO)")
	serial := flag.String("serial", "", "where the virtio console goes")
	efiVars := flag.String("efi-vars", "", "EFI variable store (EFI boot; created if missing)")
	kernel := flag.String("kernel", "", "a kernel to boot directly instead of EFI")
	initrd := flag.String("initrd", "", "the initrd for -kernel")
	cmdline := flag.String("cmdline", "", "the command line for -kernel")
	cpus := flag.Uint("cpus", 4, "vCPUs")
	memory := flag.Uint64("memory", 8192, "memory in MiB")
	nested := flag.Bool("nested", false, "nested virtualization (KVM in the guest)")
	mac := flag.String("mac", "", "the NIC's MAC address (random when empty)")
	flag.Parse()

	if err := run(disks, *iso, *serial, *efiVars, *kernel, *initrd, *cmdline, *cpus, *memory, *nested, *mac); err != nil {
		fmt.Fprintln(os.Stderr, "hostvm-dev:", err)
		os.Exit(1)
	}
}

func run(disks []string, iso, serial, efiVars, kernel, initrd, cmdline string, cpus uint, memory uint64, nested bool, mac string) error {
	if len(disks) == 0 || serial == "" {
		return errors.New("-disk and -serial are required")
	}

	var boot vz.BootLoader
	var err error
	if kernel != "" {
		opts := []vz.LinuxBootLoaderOption{vz.WithCommandLine(cmdline)}
		if initrd != "" {
			opts = append(opts, vz.WithInitrd(initrd))
		}
		boot, err = vz.NewLinuxBootLoader(kernel, opts...)
	} else {
		if efiVars == "" {
			return errors.New("-efi-vars or -kernel is required")
		}
		var store *vz.EFIVariableStore
		if _, statErr := os.Stat(efiVars); statErr == nil {
			store, err = vz.NewEFIVariableStore(efiVars)
		} else {
			store, err = vz.NewEFIVariableStore(efiVars, vz.WithCreatingEFIVariableStore())
		}
		if err != nil {
			return fmt.Errorf("EFI variable store: %w", err)
		}
		boot, err = vz.NewEFIBootLoader(vz.WithEFIVariableStore(store))
	}
	if err != nil {
		return fmt.Errorf("boot loader: %w", err)
	}

	cfg, err := vz.NewVirtualMachineConfiguration(boot, cpus, memory<<20)
	if err != nil {
		return err
	}

	platform, err := vz.NewGenericPlatformConfiguration()
	if err != nil {
		return err
	}
	if nested {
		if !vz.IsNestedVirtualizationSupported() {
			return errors.New("nested virtualization is not supported on this Mac (it needs an M3 or later and macOS 15)")
		}
		if err := platform.SetNestedVirtualizationEnabled(true); err != nil {
			return err
		}
	}
	cfg.SetPlatformVirtualMachineConfiguration(platform)

	var storage []vz.StorageDeviceConfiguration
	for i, path := range append(append([]string{}, disks...), iso) {
		if path == "" {
			continue
		}
		att, err := vz.NewDiskImageStorageDeviceAttachment(path, i >= len(disks))
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		blk, err := vz.NewVirtioBlockDeviceConfiguration(att)
		if err != nil {
			return err
		}
		storage = append(storage, blk)
	}
	cfg.SetStorageDevicesVirtualMachineConfiguration(storage)

	nat, err := vz.NewNATNetworkDeviceAttachment()
	if err != nil {
		return err
	}
	nic, err := vz.NewVirtioNetworkDeviceConfiguration(nat)
	if err != nil {
		return err
	}
	if mac != "" {
		parsed, err := net.ParseMAC(mac)
		if err != nil {
			return fmt.Errorf("-mac: %w", err)
		}
		hw, err := vz.NewMACAddress(parsed)
		if err != nil {
			return fmt.Errorf("-mac: %w", err)
		}
		nic.SetMACAddress(hw)
	}
	cfg.SetNetworkDevicesVirtualMachineConfiguration([]*vz.VirtioNetworkDeviceConfiguration{nic})

	out, err := os.OpenFile(serial, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer out.Close()
	in, err := os.Open(os.DevNull)
	if err != nil {
		return err
	}
	defer in.Close()
	att, err := vz.NewFileHandleSerialPortAttachment(in, out)
	if err != nil {
		return err
	}
	console, err := vz.NewVirtioConsoleDeviceSerialPortConfiguration(att)
	if err != nil {
		return err
	}
	cfg.SetSerialPortsVirtualMachineConfiguration([]*vz.VirtioConsoleDeviceSerialPortConfiguration{console})

	rng, err := vz.NewVirtioEntropyDeviceConfiguration()
	if err != nil {
		return err
	}
	cfg.SetEntropyDevicesVirtualMachineConfiguration([]*vz.VirtioEntropyDeviceConfiguration{rng})

	if ok, err := cfg.Validate(); !ok || err != nil {
		return fmt.Errorf("configuration: %v", err)
	}

	vm, err := vz.NewVirtualMachine(cfg)
	if err != nil {
		return err
	}
	if err := vm.Start(); err != nil {
		return fmt.Errorf("start: %w", err)
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	var deadline <-chan time.Time

	for {
		select {
		case state := <-vm.StateChangedNotify():
			if state == vz.VirtualMachineStateStopped {
				return nil
			}
			if state == vz.VirtualMachineStateError {
				return errors.New("the VM stopped with an error")
			}
		case <-signals:
			if _, err := vm.RequestStop(); err != nil {
				_ = vm.Stop()
				return nil
			}
			deadline = time.After(60 * time.Second)
		case <-deadline:
			_ = vm.Stop()
			return nil
		}
	}
}
