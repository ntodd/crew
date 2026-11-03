//go:build darwin

// Package vm builds and runs a job VM with Apple's Virtualization.framework
// (through github.com/Code-Hex/vz/v3). It implements helper.Machine.
package vm

import (
	"errors"
	"fmt"
	"os"
	"sync"

	vz "github.com/Code-Hex/vz/v3"
	"github.com/ntodd/crew/native/crew-vz/config"
	"github.com/ntodd/crew/native/crew-vz/helper"
)

// Machine is one VZVirtualMachine.
type Machine struct {
	vm     *vz.VirtualMachine
	states chan helper.State
	// The framework doesn't own these descriptors; keep the files alive.
	keep []*os.File

	mu        sync.Mutex
	lastState helper.State
}

// Limits reports what Virtualization.framework allows on this Mac.
func Limits() config.Limits {
	minMiB := int((vz.VirtualMachineConfigurationMinimumAllowedMemorySize() + (1<<20 - 1)) >> 20)
	return config.Limits{
		MinVCPUs:     int(vz.VirtualMachineConfigurationMinimumAllowedCPUCount()),
		MaxVCPUs:     int(vz.VirtualMachineConfigurationMaximumAllowedCPUCount()),
		MinMemoryMiB: max(minMiB, 1),
		MaxMemoryMiB: int(vz.VirtualMachineConfigurationMaximumAllowedMemorySize() >> 20),
	}
}

// New builds the VM described by s (§11.4):
//   - VZLinuxBootLoader: the uncompressed arm64 Image and the command line,
//     no initrd;
//   - cpuCount and memorySize;
//   - a virtio block device on the clone, read-write;
//   - a virtio entropy device;
//   - a virtio console port wired to the helper's console pipe (the helper
//     caps console.log);
//   - a virtio NIC on VZFileHandleNetworkDeviceAttachment over the frame
//     socketpair, with the lease's MAC.
func New(s helper.MachineSpec) (helper.Machine, error) {
	cfg := s.Config
	n := cfg.Net()

	boot, err := vz.NewLinuxBootLoader(cfg.Kernel, vz.WithCommandLine(cfg.Cmdline))
	if err != nil {
		return nil, fmt.Errorf("boot loader: %w", err)
	}
	vmc, err := vz.NewVirtualMachineConfiguration(boot, uint(cfg.VCPUs), uint64(cfg.MemoryMiB)<<20)
	if err != nil {
		return nil, fmt.Errorf("configuration: %w", err)
	}

	// The disk is a throwaway clone: skip host fsyncs.
	disk, err := vz.NewDiskImageStorageDeviceAttachmentWithCacheAndSync(cfg.Disk, false,
		vz.DiskImageCachingModeAutomatic, vz.DiskImageSynchronizationModeNone)
	if err != nil {
		return nil, fmt.Errorf("disk %s: %w", cfg.Disk, err)
	}
	blk, err := vz.NewVirtioBlockDeviceConfiguration(disk)
	if err != nil {
		return nil, fmt.Errorf("block device: %w", err)
	}
	vmc.SetStorageDevicesVirtualMachineConfiguration([]vz.StorageDeviceConfiguration{blk})

	rng, err := vz.NewVirtioEntropyDeviceConfiguration()
	if err != nil {
		return nil, fmt.Errorf("entropy device: %w", err)
	}
	vmc.SetEntropyDevicesVirtualMachineConfiguration([]*vz.VirtioEntropyDeviceConfiguration{rng})

	serial, err := vz.NewFileHandleSerialPortAttachment(s.ConsoleIn, s.ConsoleOut)
	if err != nil {
		return nil, fmt.Errorf("console: %w", err)
	}
	consoleDev, err := vz.NewVirtioConsoleDeviceSerialPortConfiguration(serial)
	if err != nil {
		return nil, fmt.Errorf("console: %w", err)
	}
	vmc.SetSerialPortsVirtualMachineConfiguration([]*vz.VirtioConsoleDeviceSerialPortConfiguration{consoleDev})

	netAtt, err := vz.NewFileHandleNetworkDeviceAttachment(s.Net)
	if err != nil {
		return nil, fmt.Errorf("network attachment: %w", err)
	}
	if n.MTU != 1500 {
		if err := netAtt.SetMaximumTransmissionUnit(n.MTU); err != nil {
			return nil, fmt.Errorf("network mtu: %w", err)
		}
	}
	nic, err := vz.NewVirtioNetworkDeviceConfiguration(netAtt)
	if err != nil {
		return nil, fmt.Errorf("network device: %w", err)
	}
	mac, err := vz.NewMACAddress(n.GuestMAC)
	if err != nil {
		return nil, fmt.Errorf("mac: %w", err)
	}
	nic.SetMACAddress(mac)
	vmc.SetNetworkDevicesVirtualMachineConfiguration([]*vz.VirtioNetworkDeviceConfiguration{nic})

	if ok, err := vmc.Validate(); err != nil || !ok {
		if err == nil {
			err = errors.New("invalid configuration")
		}
		return nil, fmt.Errorf("validate: %w", err)
	}
	v, err := vz.NewVirtualMachine(vmc)
	if err != nil {
		return nil, fmt.Errorf("create VM: %w", err)
	}
	m := &Machine{
		vm:     v,
		states: make(chan helper.State, 64),
		keep:   []*os.File{s.Net, s.ConsoleIn, s.ConsoleOut},
	}
	go m.forward()
	return m, nil
}

func (m *Machine) forward() {
	for st := range m.vm.StateChangedNotify() {
		hs := mapState(st)
		m.mu.Lock()
		m.lastState = hs
		m.mu.Unlock()
		m.states <- hs
	}
}

func mapState(s vz.VirtualMachineState) helper.State {
	switch s {
	case vz.VirtualMachineStateStarting:
		return helper.StateStarting
	case vz.VirtualMachineStateRunning, vz.VirtualMachineStatePausing,
		vz.VirtualMachineStatePaused, vz.VirtualMachineStateResuming,
		vz.VirtualMachineStateSaving, vz.VirtualMachineStateRestoring:
		return helper.StateRunning
	case vz.VirtualMachineStateStopping:
		return helper.StateStopping
	case vz.VirtualMachineStateError:
		return helper.StateError
	}
	return helper.StateStopped
}

func (m *Machine) Start() error { return m.vm.Start() }

// RequestStop presses the guest's power button.
func (m *Machine) RequestStop() error {
	if !m.vm.CanRequestStop() {
		return fmt.Errorf("VM can't take a stop request in state %s", m.State())
	}
	ok, err := m.vm.RequestStop()
	if err != nil {
		return err
	}
	if !ok {
		return errors.New("stop request not delivered")
	}
	return nil
}

// Stop stops the VM immediately.
func (m *Machine) Stop() error {
	if !m.vm.CanStop() {
		return fmt.Errorf("VM can't be stopped in state %s", m.State())
	}
	return m.vm.Stop()
}

func (m *Machine) State() helper.State { return mapState(m.vm.State()) }

func (m *Machine) StateChanges() <-chan helper.State { return m.states }
