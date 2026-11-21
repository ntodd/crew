package vmctl

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCloudJobConfig(t *testing.T) {
	p := Paths{Data: "/srv/crew"}
	now := time.Now()
	n, err := ParseVMNet("10.200.0.0/16")
	if err != nil {
		t.Fatal(err)
	}
	vm, err := ParseVM(vmJSON(now.Unix()+3600), vmID, n, now)
	if err != nil {
		t.Fatal(err)
	}
	body, err := ChrootConfig(encode(t, agentFC()), vm, p)
	if err != nil {
		t.Fatal(err)
	}
	var checked fcConfig
	if err = json.Unmarshal(body, &checked); err != nil {
		t.Fatal(err)
	}
	job, err := cloudConfig(checked, p.Chroot(vmID))
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Landlock bool `json:"landlock_enable"`
		Payload  struct{ Kernel, Cmdline string }
		Cpus     struct {
			Boot int `json:"boot_vcpus"`
		}
		Memory struct {
			Size int64
			THP  *bool `json:"thp"`
		}
		Disks []struct {
			Path    string
			Limiter *rateLimiter `json:"rate_limiter_config"`
		}
		Net []struct {
			Tap, Mac string
			Limiter  *rateLimiter `json:"rate_limiter_config"`
		}
	}
	if err = json.Unmarshal(job, &got); err != nil {
		t.Fatal(err)
	}
	if got.Memory.THP == nil || *got.Memory.THP {
		t.Fatal("expected explicit memory.thp=false in the Cloud Hypervisor request")
	}
	if got.Payload.Cmdline != checked.BootSource.BootArgs || got.Payload.Kernel != filepath.Join(p.Chroot(vmID), "kernel") ||
		got.Cpus.Boot != vm.VCPUs || got.Memory.Size != int64(BootMiB(vm.MemoryMiB))<<20 ||
		len(got.Disks) != 1 || got.Disks[0].Path != filepath.Join(p.Chroot(vmID), "rootfs.ext4") ||
		len(got.Net) != 1 || got.Net[0].Tap != vm.Lease.Tap || got.Net[0].Mac != vm.Lease.MAC {
		t.Fatalf("wrong Cloud Hypervisor request: %s", job)
	}
	if !got.Landlock || got.Disks[0].Limiter == nil || got.Disks[0].Limiter.Ops == nil ||
		got.Net[0].Limiter == nil || got.Net[0].Limiter.Bandwidth == nil || got.Disks[0].Limiter.Ops.Size != 3000 || got.Net[0].Limiter.Bandwidth.Size != 125000000 {
		t.Fatal("job must keep filesystem confinement and disk/network limits")
	}
	argv := strings.Join(cloudUnit(vm, p, now), " ")
	for _, want := range []string{"--reuid=200003", "--regid=200003", "--bounding-set=-all", "--groups=kvm", "--slice=crew-jobs.slice", "RuntimeMaxSec=", "DeviceAllow=/dev/kvm rw", "ExecStopPost=" + p.Vmctl() + " exited " + vmID, "cloud-run " + vmID} {
		if !strings.Contains(argv, want) {
			t.Errorf("missing %q in %s", want, argv)
		}
	}
	if strings.Contains(argv, got.Payload.Cmdline) {
		t.Error("kernel arguments exposed in unit")
	}
	checked.NetworkInterfaces[0].RxRateLimiter = nil
	if _, err := cloudConfig(checked, p.Chroot(vmID)); err == nil {
		t.Fatal("accepted unequal receive and transmit limits")
	}
}

func TestNativeForwarding(t *testing.T) {
	sys := newFake()
	original, err := networkScript(sys, "eth0")
	if err != nil {
		t.Fatal(err)
	}
	sys.exists["/etc/crew-box/native-worker"] = true
	shared, err := networkScript(sys, "eth0")
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(strings.TrimPrefix(shared, original)) != `add rule inet crew forward iifname != "crewt*" oifname != "crewt*" accept` {
		t.Fatal("unexpected change to shared-host firewall")
	}
}

// Exercise the socket inherited by the VMM, both HTTP operations, the
// systemd readiness signal, and propagation of the child's exit status.
func TestCloudLauncher(t *testing.T) {
	p := Paths{Data: t.TempDir()}
	dir := p.Chroot(vmID)
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(p.bin("cloud-hypervisor")), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "fc.json"), encode(t, agentFC()), 0400); err != nil {
		t.Fatal(err)
	}
	// Use a second invocation of this test executable as a local VMM API.
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\nexec \"" + exe + "\" -test.run=TestInheritedCloudAPI\n"
	if err = os.WriteFile(p.bin("cloud-hypervisor"), []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	// Short socket paths also work with Darwin's sockaddr_un.
	folder, err := os.MkdirTemp("/tmp", "crew-notify-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(folder)
	t.Setenv("TMPDIR", folder)
	sock, err := net.ListenUnixgram("unixgram", &net.UnixAddr{Name: filepath.Join(folder, "notify"), Net: "unixgram"})
	if err != nil {
		t.Fatal(err)
	}
	defer sock.Close()
	t.Setenv("CREW_TEST_INHERITED_SOCKET", "1")
	if err = RunCloud(p, vmID, sock.LocalAddr().String()); err != nil {
		t.Fatal(err)
	}
	sock.SetReadDeadline(time.Now().Add(time.Second))
	data := make([]byte, 64)
	n, err := sock.Read(data)
	if err != nil || !bytes.Equal(data[:n], []byte("READY=1")) {
		t.Fatalf("notify: %q %v", data[:n], err)
	}
}

func TestInheritedCloudAPI(t *testing.T) {
	if os.Getenv("CREW_TEST_INHERITED_SOCKET") != "1" {
		t.Skip("child process")
	}
	fd := os.NewFile(3, "api")
	defer fd.Close()
	listener, err := net.FileListener(fd)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	for _, action := range []string{"vm.create", "vm.boot"} {
		conn, err := listener.Accept()
		if err != nil {
			t.Fatal(err)
		}
		request, err := http.ReadRequest(bufio.NewReader(conn))
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Fatal(err)
		}
		request.Body.Close()
		if request.Method != "PUT" || request.URL.Path != "/api/v1/"+action || (action == "vm.create" && !json.Valid(body)) {
			t.Fatal("invalid API request")
		}
		fmt.Fprint(conn, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
		conn.Close()
	}
}
