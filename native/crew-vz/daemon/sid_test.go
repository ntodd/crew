package daemon

import (
	"os"

	"golang.org/x/sys/unix"
)

func getsid(pid int) (int, error) { return unix.Getsid(pid) }

func mySid() int {
	sid, _ := unix.Getsid(os.Getpid())
	return sid
}
