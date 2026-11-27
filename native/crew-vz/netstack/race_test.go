//go:build race

package netstack

func init() { raceEnabled = true }
