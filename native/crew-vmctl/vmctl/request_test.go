package vmctl

import (
	"strings"
	"testing"
)

const vmID = "0195f3a2-7c4e-7b1a-9f00-0123456789ab"

func TestParseAcceptsEachVerbWithItsArguments(t *testing.T) {
	for _, line := range []string{
		`{"verb":"start","vm_id":"` + vmID + `"}`,
		`{"verb":"stop","vm_id":"` + vmID + `","force":true}`,
		`{"verb":"stop","vm_id":"` + vmID + `"}`,
		`{"verb":"status","vm_id":"` + vmID + `"}`,
		`{"verb":"list"}`,
		`{"verb":"tap-add","lease_index":1}`,
		`{"verb":"tap-del","lease_index":16383}`,
		`{"verb":"pair-add","lease_index":7}`,
		`{"verb":"pair-del","lease_index":7}`,
		`{"verb":"nft-verify"}`,
		`{"verb":"reboot","boot_id":"` + vmID + `","force":false}`,
		`{"verb":"cleanup","vm_id":"` + vmID + `"}`,
		`{"verb":"restart-cache"}`,
		`{"verb":"info"}`,
	} {
		if _, err := ParseRequest([]byte(line), testNet(t)); err != nil {
			t.Errorf("%s: %v", line, err)
		}
	}
}

func TestParseRefusesAnythingElse(t *testing.T) {
	long := strings.Repeat(" ", MaxRequest+1)
	for _, tc := range []struct{ line, code string }{
		{`{"verb":"exec","cmd":"sh"}`, ErrBadRequest},
		{`{"verb":"exec"}`, ErrUnknownVerb},
		{`{"verb":"exited","vm_id":"` + vmID + `"}`, ErrUnknownVerb}, // systemd's hook, never the socket's
		{`{"verb":"start"}`, ErrBadRequest},
		{`{"verb":"start","vm_id":"../../etc"}`, ErrBadRequest},
		{`{"verb":"start","vm_id":"` + strings.ToUpper(vmID) + `"}`, ErrBadRequest},
		{`{"verb":"start","vm_id":"` + vmID + `/.."}`, ErrBadRequest},
		{`{"verb":"start","vm_id":"` + vmID + `","lease_index":3}`, ErrBadRequest},
		{`{"verb":"start","vm_id":"` + vmID + `","path":"/etc/shadow"}`, ErrBadRequest},
		{`{"verb":"stop","vm_id":"` + vmID + `","force":"yes"}`, ErrBadRequest},
		{`{"verb":"list","vm_id":"` + vmID + `"}`, ErrBadRequest},
		{`{"verb":"tap-add"}`, ErrBadRequest},
		{`{"verb":"tap-add","lease_index":0}`, ErrBadRequest},
		{`{"verb":"tap-add","lease_index":16384}`, ErrBadRequest},
		{`{"verb":"tap-add","lease_index":-1}`, ErrBadRequest},
		{`{"verb":"tap-add","lease_index":1.5}`, ErrBadRequest},
		{`{"verb":"tap-add","lease_index":"1"}`, ErrBadRequest},
		{`{"verb":"tap-add","lease_index":99999999999999999999}`, ErrBadRequest},
		{`{"verb":"pair-add","lease_index":3,"vm_id":"` + vmID + `"}`, ErrBadRequest},
		{`{"verb":"reboot"}`, ErrBadRequest},
		{`{"verb":"reboot","boot_id":"not-a-uuid"}`, ErrBadRequest},
		{`{"verb":"nft-verify","force":true}`, ErrBadRequest},
		{`{"verb":"start","vm_id":"` + vmID + `"}{"verb":"list"}`, ErrBadRequest},
		{`[]`, ErrBadRequest},
		{``, ErrBadRequest},
		{long, ErrBadRequest},
	} {
		_, err := ParseRequest([]byte(tc.line), testNet(t))
		if err == nil {
			t.Errorf("%.80s: accepted", tc.line)
			continue
		}
		if code := ErrorCode(err); code != tc.code {
			t.Errorf("%.80s: code %q, want %q (%v)", tc.line, code, tc.code, err)
		}
	}
}

func TestUUIDs(t *testing.T) {
	for _, ok := range []string{vmID, "00000000-0000-0000-0000-000000000000"} {
		if !IsUUID(ok) {
			t.Errorf("%s: want a UUID", ok)
		}
	}
	for _, bad := range []string{"", "0195f3a2-7c4e-7b1a-9f00-0123456789a", "0195f3a27c4e7b1a9f000123456789ab",
		"0195f3a2-7c4e-7b1a-9f00-0123456789ab\n", "0195f3a2-7c4e-7b1a-9f00-0123456789aG", "../0195f3a2-7c4e-7b1a-9f00-01234567"} {
		if IsUUID(bad) {
			t.Errorf("%q: want not a UUID", bad)
		}
	}
}

func testNet(t *testing.T) VMNet {
	t.Helper()
	n, err := ParseVMNet("10.200.0.0/16")
	if err != nil {
		t.Fatal(err)
	}
	return n
}
