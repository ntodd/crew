package netstack

import (
	"fmt"
	"net"
	"os"
	"syscall"
)

// Socket buffer sizes for the frame socketpair. Virtualization.framework
// wants SO_RCVBUF at least twice SO_SNDBUF and recommends four times; a
// datagram can't be larger than SO_SNDBUF.
const (
	sndBuf = 1 << 20
	rcvBuf = 4 << 20
)

// TuneSocket sizes one end of the frame socketpair.
func TuneSocket(fd int, mtu int) error {
	if mtu+ethHeaderLen > sndBuf {
		return fmt.Errorf("mtu %d too large for a %d-byte send buffer", mtu, sndBuf)
	}
	if err := syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_SNDBUF, sndBuf); err != nil {
		return os.NewSyscallError("setsockopt SO_SNDBUF", err)
	}
	if err := syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, rcvBuf); err != nil {
		return os.NewSyscallError("setsockopt SO_RCVBUF", err)
	}
	return nil
}

// Socketpair makes the VM's frame link: vmEnd goes to
// VZFileHandleNetworkDeviceAttachment, helperEnd to Netstack.Run.
func Socketpair(mtu int) (vmEnd *os.File, helperEnd *net.UnixConn, err error) {
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0)
	if err != nil {
		return nil, nil, os.NewSyscallError("socketpair", err)
	}
	for _, fd := range fds {
		syscall.CloseOnExec(fd)
		if err := TuneSocket(fd, mtu); err != nil {
			syscall.Close(fds[0])
			syscall.Close(fds[1])
			return nil, nil, err
		}
	}
	vmEnd = os.NewFile(uintptr(fds[0]), "vz-net-vm")
	hf := os.NewFile(uintptr(fds[1]), "vz-net-helper")
	c, err := net.FileConn(hf)
	hf.Close()
	if err != nil {
		vmEnd.Close()
		return nil, nil, err
	}
	return vmEnd, c.(*net.UnixConn), nil
}
