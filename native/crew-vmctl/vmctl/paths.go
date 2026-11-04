package vmctl

import "path/filepath"

// Paths builds every path crew-vmctl touches from the data directory
// (§10.1). None comes from a request.
type Paths struct {
	Data string // /srv/crew
}

// DefaultData is the data directory on a Flatcar box.
const DefaultData = "/srv/crew"

// RootDir is where, under the data directory, the box keeps what root
// runs: root/<version>/, installed by root from the release tarball, and
// root/current, the link to the one in use. Root's all the way down, so
// unlike agent/ (the agent updates itself there) nothing the agent can
// write is run as root. A constant: crew-vmctl takes no path from the
// agent, and this one not from its own flags either.
const RootDir = "root"

func (p Paths) bin(name string) string {
	return filepath.Join(p.Data, RootDir, "current", "bin", name)
}

// Jailer, Firecracker and Vmctl are the release's binaries, through
// root/current. §11.3's unit names agent/current/bin; that's the agent's
// to write, so they're not run from there.
func (p Paths) Jailer() string      { return p.bin("jailer") }
func (p Paths) Firecracker() string { return p.bin("firecracker") }
func (p Paths) Vmctl() string       { return p.bin("crew-vmctl") }

// JailBase is jailer's --chroot-base-dir. Root's, like everything under it.
func (p Paths) JailBase() string { return filepath.Join(p.Data, "jail") }

// JailDir is a VM's directory in the jail: jailer's chroot is its
// root/, and crew-vmctl keeps the files systemd and it write as root
// beside it (console.log, fc.stderr, exited.json, lease), where the
// agent can't put a symlink in their way.
func (p Paths) JailDir(vmID string) string {
	return filepath.Join(p.JailBase(), "firecracker", vmID)
}

func (p Paths) Chroot(vmID string) string { return filepath.Join(p.JailDir(vmID), "root") }

func (p Paths) Console(vmID string) string { return filepath.Join(p.JailDir(vmID), "console.log") }
func (p Paths) Stderr(vmID string) string  { return filepath.Join(p.JailDir(vmID), "fc.stderr") }
func (p Paths) Exited(vmID string) string  { return filepath.Join(p.JailDir(vmID), "exited.json") }

// VMsDir and VMDir are the agent's (§10.1): crew-vmctl reads them with
// care, never following a symlink.
func (p Paths) VMsDir() string             { return filepath.Join(p.Data, "vms") }
func (p Paths) VMDir(vmID string) string   { return filepath.Join(p.VMsDir(), vmID) }
func (p Paths) Clone(vmID string) string   { return filepath.Join(p.VMDir(vmID), "rootfs.ext4") }
func (p Paths) ImagesDir() string          { return filepath.Join(p.Data, "images") }
func (p Paths) Kernel(image string) string { return filepath.Join(p.ImagesDir(), image, "kernel") }

// AgentEnv is the agent's settings (§21.2). crew-vmctl reads nothing from
// it: what root's packet filter is built from comes from root's files.
func (p Paths) AgentEnv() string { return filepath.Join(p.Data, "agent", "env") }

// StateDir is crew-vmctl's own state on the data disk (it outlives the
// OS disk, §10.1), root's: <data>/vmctl, beside root/.
const StateDir = "vmctl"

// State is a file in StateDir.
func (p Paths) State(name string) string { return filepath.Join(p.Data, StateDir, name) }

// The box's own settings for the packet filter, which its Ignition
// writes, root's (0644): CREW_EXTRA_BLOCKED and CREW_UPLINK, never read
// from the agent's env.
const (
	ExtraBlockedFile = "/etc/crew-box/extra-blocked" // CIDRs, by commas or lines; # comments
	UplinkFile       = "/etc/crew-box/uplink"        // one interface name; else the default route's
)

// Egress is where the agent keeps the site's egress address (§14.2).
func (p Paths) Egress() string { return filepath.Join(p.Data, "agent", "egress4") }

// The unit for a VM.
func Unit(vmID string) string { return "crew-vm-" + vmID + ".service" }
