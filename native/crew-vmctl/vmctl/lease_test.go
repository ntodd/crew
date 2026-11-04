package vmctl

import "testing"

func TestLeaseMatchesTheAgent(t *testing.T) {
	// CrewAgent.Net.lease/2: lease n is the n-th /30 of the VM range,
	// .1 the gateway, .2 the guest, and the MAC is 02:c2 and the guest IP.
	n, err := ParseVMNet("10.200.0.0/16")
	if err != nil {
		t.Fatal(err)
	}
	l, err := n.Lease(3)
	if err != nil {
		t.Fatal(err)
	}
	want := Lease{Index: 3, Tap: "crewt3", UID: 200003, GID: 200003,
		Gateway: "10.200.0.13", Guest: "10.200.0.14", MAC: "02:c2:0a:c8:00:0e"}
	if l != want {
		t.Fatalf("lease 3 = %+v, want %+v", l, want)
	}

	last, err := n.Lease(16383)
	if err != nil {
		t.Fatal(err)
	}
	if last.Guest != "10.200.255.254" || last.Tap != "crewt16383" || last.UID != 216383 {
		t.Fatalf("lease 16383 = %+v", last)
	}
}

func TestLeaseIndexIsBounded(t *testing.T) {
	n, _ := ParseVMNet("10.200.0.0/16")
	for _, i := range []int{-1, 0, 16384, 1 << 40} {
		if _, err := n.Lease(i); err == nil {
			t.Errorf("lease %d: want an error", i)
		}
	}
	small, _ := ParseVMNet("10.200.0.0/24")
	if _, err := small.Lease(64); err == nil {
		t.Error("a /24 has 64 leases, 0 to 63")
	}
	if _, err := small.Lease(63); err != nil {
		t.Error(err)
	}
}

func TestVMNetIsPrivateAndSane(t *testing.T) {
	for _, bad := range []string{
		"", "10.200.0.0", "10.200.0.1/16", "10.200.0.0/15", "10.200.0.0/29",
		"8.8.0.0/16", "fd00::/64", "10.200.0.0/16 ", "010.200.0.0/16", "10.200.0.0/016",
	} {
		if _, err := ParseVMNet(bad); err == nil {
			t.Errorf("ParseVMNet(%q): want an error", bad)
		}
	}
	for _, ok := range []string{"10.200.0.0/16", "172.20.0.0/16", "192.168.128.0/20", "100.80.0.0/16"} {
		if _, err := ParseVMNet(ok); err != nil {
			t.Errorf("ParseVMNet(%q): %v", ok, err)
		}
	}
}
