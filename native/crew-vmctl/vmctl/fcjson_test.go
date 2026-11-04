package vmctl

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

var paths = Paths{Data: "/srv/crew"}

const imageID = "0195f3a2-0000-7000-8000-00000000beef"

// vm.json as CrewAgent.VM writes it (the fields crew-vmctl reads, and
// others it ignores).
func vmJSON(deadline int64) []byte {
	return []byte(`{"vm_id":"` + vmID + `","name":"crew-1-m-abc","image":{"id":"` + imageID + `",
	"version":"0.1.0","arch":"arm64","manifest_sha256":"00"},"size":{"vcpus":4,"memory_mib":8192,
	"disk_gib":60,"limits":{"net_bandwidth_mbps":1000}},"deadline":` + itoa(deadline) + `,
	"lease_index":3,"created_at":1,"log_limit_bytes":100,"policy":{"fork_prs":"refuse"},"labels":["crew-m"]}`)
}

// fc.json as the agent's Firecracker driver writes it.
func agentFC() map[string]any {
	limiter := map[string]any{"bandwidth": map[string]any{"size": 125000000, "refill_time": 1000}}
	return map[string]any{
		"boot-source": map[string]any{
			"kernel_image_path": "/srv/crew/images/" + imageID + "/kernel",
			"boot_args":         "console=ttyS0 panic=1 quiet loglevel=4 root=/dev/vda rw crew.vm=" + vmID,
		},
		"drives": []any{map[string]any{
			"drive_id": "rootfs", "path_on_host": "/srv/crew/vms/" + vmID + "/rootfs.ext4",
			"is_root_device": true, "is_read_only": false,
			"rate_limiter": map[string]any{"ops": map[string]any{"size": 3000, "refill_time": 1000}},
		}},
		"machine-config": map[string]any{"vcpu_count": 4, "mem_size_mib": 8192, "smt": false},
		"network-interfaces": []any{map[string]any{
			"iface_id": "eth0", "host_dev_name": "crewt3", "guest_mac": "02:c2:0a:c8:00:0e",
			"rx_rate_limiter": limiter, "tx_rate_limiter": limiter,
		}},
		"entropy": map[string]any{},
	}
}

func encode(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func future() int64 { return time.Now().Unix() + 3600 }

func TestParseVM(t *testing.T) {
	vm, err := ParseVM(vmJSON(future()), vmID, testNet(t), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if vm.ImageID != imageID || vm.VCPUs != 4 || vm.MemoryMiB != 8192 || vm.Lease.Index != 3 || vm.Lease.Tap != "crewt3" {
		t.Fatalf("%+v", vm)
	}
}

func TestParseVMRefusesBadRecords(t *testing.T) {
	now := time.Now()
	good := string(vmJSON(future()))
	for name, body := range map[string]string{
		"another vm":      strings.Replace(good, vmID, "0195f3a2-7c4e-7b1a-9f00-0123456789ac", 1),
		"image not uuid":  strings.Replace(good, imageID, "../../etc", 1),
		"odd vcpus":       strings.Replace(good, `"vcpus":4`, `"vcpus":3`, 1),
		"too many vcpus":  strings.Replace(good, `"vcpus":4`, `"vcpus":34`, 1),
		"small memory":    strings.Replace(good, `"memory_mib":8192`, `"memory_mib":512`, 1),
		"huge memory":     strings.Replace(good, `"memory_mib":8192`, `"memory_mib":2097152`, 1),
		"lease 0":         strings.Replace(good, `"lease_index":3`, `"lease_index":0`, 1),
		"lease too big":   strings.Replace(good, `"lease_index":3`, `"lease_index":16384`, 1),
		"deadline passed": strings.Replace(good, itoa(future()), itoa(now.Unix()-1), 1),
		"deadline far":    strings.Replace(good, itoa(future()), itoa(now.Unix()+8*24*3600), 1),
		"not json":        "{",
		"too large":       `{"x":"` + strings.Repeat("a", MaxFile) + `"}`,
	} {
		if _, err := ParseVM([]byte(body), vmID, testNet(t), now); err == nil {
			t.Errorf("%s: accepted", name)
		} else if ErrorCode(err) != ErrInvalidConfig {
			t.Errorf("%s: code %s", name, ErrorCode(err))
		}
	}
}

func TestChrootConfig(t *testing.T) {
	vm, err := ParseVM(vmJSON(future()), vmID, testNet(t), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	out, err := ChrootConfig(encode(t, agentFC()), vm, paths)
	if err != nil {
		t.Fatal(err)
	}
	// Paths are the chroot's, the logger and metrics are crew-vmctl's own.
	want := `{
  "boot-source": {
    "kernel_image_path": "/kernel",
    "boot_args": "console=ttyS0 panic=1 quiet loglevel=4 root=/dev/vda rw crew.vm=` + vmID + `"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "/rootfs.ext4",
      "is_root_device": true,
      "is_read_only": false,
      "rate_limiter": {
        "ops": {
          "size": 3000,
          "refill_time": 1000
        }
      }
    }
  ],
  "machine-config": {
    "vcpu_count": 4,
    "mem_size_mib": 8192,
    "smt": false
  },
  "network-interfaces": [
    {
      "iface_id": "eth0",
      "host_dev_name": "crewt3",
      "guest_mac": "02:c2:0a:c8:00:0e",
      "rx_rate_limiter": {
        "bandwidth": {
          "size": 125000000,
          "refill_time": 1000
        }
      },
      "tx_rate_limiter": {
        "bandwidth": {
          "size": 125000000,
          "refill_time": 1000
        }
      }
    }
  ],
  "entropy": {},
  "logger": {
    "log_path": "/fc.log",
    "level": "Warning",
    "show_level": true,
    "show_log_origin": false
  },
  "metrics": {
    "metrics_path": "/fc.metrics"
  }
}
`
	if string(out) != want {
		t.Fatalf("chroot fc.json:\n%s\nwant:\n%s", out, want)
	}
}

func TestChrootConfigWithoutLimits(t *testing.T) {
	vm, _ := ParseVM(vmJSON(future()), vmID, testNet(t), time.Now())
	fc := agentFC()
	delete(fc["drives"].([]any)[0].(map[string]any), "rate_limiter")
	n := fc["network-interfaces"].([]any)[0].(map[string]any)
	delete(n, "rx_rate_limiter")
	delete(n, "tx_rate_limiter")
	out, err := ChrootConfig(encode(t, fc), vm, paths)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(out), "rate_limiter") {
		t.Fatalf("no limits, no limiters:\n%s", out)
	}
}

func TestChrootConfigRefusesWhatTheAgentMustNotChoose(t *testing.T) {
	vm, _ := ParseVM(vmJSON(future()), vmID, testNet(t), time.Now())
	other := "0195f3a2-7c4e-7b1a-9f00-0123456789ac"
	cases := map[string]func(fc map[string]any){
		"kernel elsewhere": func(fc map[string]any) { bs(fc)["kernel_image_path"] = "/etc/shadow" },
		"kernel traversal": func(fc map[string]any) {
			bs(fc)["kernel_image_path"] = "/srv/crew/images/" + imageID + "/../../agent/identity.json"
		},
		"another image's kernel": func(fc map[string]any) { bs(fc)["kernel_image_path"] = "/srv/crew/images/" + other + "/kernel" },
		"an initrd":              func(fc map[string]any) { bs(fc)["initrd_path"] = "/srv/crew/images/" + imageID + "/kernel" },
		"boot args newline":      func(fc map[string]any) { bs(fc)["boot_args"] = "console=ttyS0\ninit=/bin/sh" },
		"boot args empty":        func(fc map[string]any) { bs(fc)["boot_args"] = "" },
		"boot args too long":     func(fc map[string]any) { bs(fc)["boot_args"] = strings.Repeat("a", 2049) },
		"boot args non-ascii":    func(fc map[string]any) { bs(fc)["boot_args"] = "console=ttyS0 é" },
		"another VM's disk":      func(fc map[string]any) { drv(fc)["path_on_host"] = "/srv/crew/vms/" + other + "/rootfs.ext4" },
		"the image's disk":       func(fc map[string]any) { drv(fc)["path_on_host"] = "/srv/crew/images/" + imageID + "/rootfs.ext4" },
		"a block device":         func(fc map[string]any) { drv(fc)["path_on_host"] = "/dev/vda" },
		"read-only root":         func(fc map[string]any) { drv(fc)["is_read_only"] = true },
		"not the root":           func(fc map[string]any) { drv(fc)["is_root_device"] = false },
		"another drive id":       func(fc map[string]any) { drv(fc)["drive_id"] = "data" },
		"a second drive": func(fc map[string]any) {
			fc["drives"] = append(fc["drives"].([]any), map[string]any{"drive_id": "x", "path_on_host": "/etc/shadow",
				"is_root_device": false, "is_read_only": true})
		},
		"no drives":          func(fc map[string]any) { fc["drives"] = []any{} },
		"a vhost socket":     func(fc map[string]any) { drv(fc)["socket"] = "/run/x.sock" },
		"io engine":          func(fc map[string]any) { drv(fc)["io_engine"] = "Async" },
		"vcpus differ":       func(fc map[string]any) { mc(fc)["vcpu_count"] = 8 },
		"memory differs":     func(fc map[string]any) { mc(fc)["mem_size_mib"] = 65536 },
		"smt":                func(fc map[string]any) { mc(fc)["smt"] = true },
		"huge pages":         func(fc map[string]any) { mc(fc)["huge_pages"] = "2M" },
		"another tap":        func(fc map[string]any) { nic(fc)["host_dev_name"] = "eth0" },
		"another lease":      func(fc map[string]any) { nic(fc)["host_dev_name"] = "crewt4" },
		"another MAC":        func(fc map[string]any) { nic(fc)["guest_mac"] = "02:c2:0a:c8:00:12" },
		"another iface":      func(fc map[string]any) { nic(fc)["iface_id"] = "eth1" },
		"two nics":           func(fc map[string]any) { fc["network-interfaces"] = append(fc["network-interfaces"].([]any), nic(fc)) },
		"no nic":             func(fc map[string]any) { fc["network-interfaces"] = []any{} },
		"no entropy":         func(fc map[string]any) { delete(fc, "entropy") },
		"its own logger":     func(fc map[string]any) { fc["logger"] = map[string]any{"log_path": "/etc/passwd"} },
		"its own metrics":    func(fc map[string]any) { fc["metrics"] = map[string]any{"metrics_path": "/etc/passwd"} },
		"a vsock":            func(fc map[string]any) { fc["vsock"] = map[string]any{"guest_cid": 3, "uds_path": "/x"} },
		"mmds":               func(fc map[string]any) { fc["mmds-config"] = map[string]any{} },
		"a balloon":          func(fc map[string]any) { fc["balloon"] = map[string]any{} },
		"refill time 0":      func(fc map[string]any) { limiter(fc)["refill_time"] = 0 },
		"refill time long":   func(fc map[string]any) { limiter(fc)["refill_time"] = 3600001 },
		"bucket size 0":      func(fc map[string]any) { limiter(fc)["size"] = 0 },
		"bucket size huge":   func(fc map[string]any) { limiter(fc)["size"] = int64(1) << 50 },
		"burst huge":         func(fc map[string]any) { limiter(fc)["one_time_burst"] = int64(1) << 50 },
		"limiter no buckets": func(fc map[string]any) { nic(fc)["rx_rate_limiter"] = map[string]any{} },
		"unknown key":        func(fc map[string]any) { fc["cpu-config"] = "/etc/passwd" },
	}
	for name, mutate := range cases {
		fc := agentFC()
		mutate(fc)
		if _, err := ChrootConfig(encode(t, fc), vm, paths); err == nil {
			t.Errorf("%s: accepted", name)
		} else if ErrorCode(err) != ErrInvalidConfig {
			t.Errorf("%s: code %s (%v)", name, ErrorCode(err), err)
		}
	}
	if _, err := ChrootConfig([]byte(`{}{}`), vm, paths); err == nil {
		t.Error("two objects: accepted")
	}
}

func bs(fc map[string]any) map[string]any  { return fc["boot-source"].(map[string]any) }
func mc(fc map[string]any) map[string]any  { return fc["machine-config"].(map[string]any) }
func drv(fc map[string]any) map[string]any { return fc["drives"].([]any)[0].(map[string]any) }
func nic(fc map[string]any) map[string]any {
	return fc["network-interfaces"].([]any)[0].(map[string]any)
}
func limiter(fc map[string]any) map[string]any {
	return nic(fc)["rx_rate_limiter"].(map[string]any)["bandwidth"].(map[string]any)
}

func itoa(n int64) string { return strings.TrimSpace(string(must(json.Marshal(n)))) }

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}
