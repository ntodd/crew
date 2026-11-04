package vmctl

import (
	"errors"
	"os"
	"strconv"
	"strings"
)

// ErrIDInUse: a VM's uid or gid belongs to someone else.
const ErrIDInUse = "id_in_use"

// The account databases a VM's ids are checked against. Flatcar's NSS
// reads /etc and then /usr/share/baselayout ("usrfiles"). /etc/passwd and
// /etc/group must be readable: without them nothing is known to be free.
var (
	passwdFiles = []idFile{{"/etc/passwd", true}, {"/usr/share/baselayout/passwd", false}}
	groupFiles  = []idFile{{"/etc/group", true}, {"/usr/share/baselayout/group", false}}
)

type idFile struct {
	path     string
	required bool
}

// checkIDs refuses a lease whose uid or gid (UIDBase + index) is a user's
// uid or primary gid, a group's gid, or inside a subordinate id range
// (/etc/subuid, /etc/subgid), so a VM never shares an identity with
// anything else on the box. The box's Ignition reserves the range.
func (s *Server) checkIDs(l Lease) error {
	inUse := func(what string) error {
		return fail(ErrIDInUse, "lease %d's %s is in use; a VM's ids are %d + the lease", l.Index, what, UIDBase)
	}
	for _, f := range passwdFiles {
		lines, err := s.idLines(f)
		if err != nil {
			return err
		}
		for _, fs := range lines {
			if len(fs) >= 4 && (fs[2] == strconv.Itoa(l.UID) || fs[3] == strconv.Itoa(l.GID)) {
				return inUse("uid or gid (" + f.path + ")")
			}
		}
	}
	for _, f := range groupFiles {
		lines, err := s.idLines(f)
		if err != nil {
			return err
		}
		for _, fs := range lines {
			if len(fs) >= 3 && fs[2] == strconv.Itoa(l.GID) {
				return inUse("gid (" + f.path + ")")
			}
		}
	}
	for _, r := range []struct {
		path string
		id   int
	}{{"/etc/subuid", l.UID}, {"/etc/subgid", l.GID}} {
		lines, err := s.idLines(idFile{r.path, false})
		if err != nil {
			return err
		}
		for _, fs := range lines {
			if len(fs) != 3 {
				continue
			}
			start, err1 := strconv.Atoi(fs[1])
			count, err2 := strconv.Atoi(fs[2])
			if err1 == nil && err2 == nil && r.id >= start && r.id-start < count {
				return inUse("id (in a range in " + r.path + ")")
			}
		}
	}
	return nil
}

// idLines reads a colon-separated account file, skipping comments.
func (s *Server) idLines(f idFile) ([][]string, error) {
	body, err := s.Sys.ReadFile(f.path, 16<<20)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) && !f.required {
			return nil, nil
		}
		return nil, fail(ErrIDInUse, "can't check the VM's ids against %s: %v", f.path, err)
	}
	var out [][]string
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, strings.Split(line, ":"))
	}
	return out, nil
}
