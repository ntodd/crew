package etc

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Everything the units run as root comes from root/current/bin, which
// only root can write; nothing from agent/, which the agent can (the
// Ignition refuses a release whose units name it).
func TestUnitsRunRootsBinaries(t *testing.T) {
	units, err := filepath.Glob("systemd/*")
	if err != nil || len(units) == 0 {
		t.Fatalf("no units: %v", err)
	}
	execs := 0
	for _, u := range units {
		body, err := os.ReadFile(u)
		if err != nil {
			t.Fatal(err)
		}
		for _, line := range strings.Split(string(body), "\n") {
			if strings.Contains(line, "/agent/") && !strings.HasPrefix(strings.TrimSpace(line), "#") {
				t.Errorf("%s names agent/: %s", u, line)
			}
			k, v, ok := strings.Cut(line, "=")
			if !ok || !strings.HasPrefix(k, "Exec") {
				continue
			}
			execs++
			if !strings.HasPrefix(v, "/srv/crew/root/current/bin/") {
				t.Errorf("%s: %s runs %s, not one of root/current/bin", u, k, v)
			}
		}
	}
	if execs != 3 {
		t.Errorf("%d Exec lines, want 3 (crew-vmctl serve, net-up, site4)", execs)
	}
}

// A socket comes before sockets.target and so before basic.target, which
// a service with the default dependencies comes after: a service ordered
// before a socket is a cycle at boot (the :kvm runner checks the whole
// boot transaction with systemd-analyze too).
func TestNoServiceIsOrderedBeforeASocket(t *testing.T) {
	services, _ := filepath.Glob("systemd/*.service")
	for _, u := range services {
		body, _ := os.ReadFile(u)
		if strings.Contains(string(body), "DefaultDependencies=no") {
			continue
		}
		for _, line := range strings.Split(string(body), "\n") {
			if k, v, ok := strings.Cut(line, "="); ok && k == "Before" && strings.Contains(v, ".socket") {
				t.Errorf("%s: %s", u, line)
			}
		}
	}
}
