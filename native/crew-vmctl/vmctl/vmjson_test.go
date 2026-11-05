package vmctl

import "testing"

// The same table as CrewProtocol.GuestMemoryTest.
func TestBootMiB(t *testing.T) {
	for size, want := range map[int]int{1024: 1090, 2048: 2133, 4096: 4219, 8192: 8391, 32768: 33422} {
		if got := BootMiB(size); got != want {
			t.Errorf("BootMiB(%d) = %d, want %d", size, got, want)
		}
	}
}
