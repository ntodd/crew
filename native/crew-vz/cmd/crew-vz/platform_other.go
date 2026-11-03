//go:build !darwin

package main

import (
	"errors"

	"github.com/ntodd/crew/native/crew-vz/config"
	"github.com/ntodd/crew/native/crew-vz/helper"
)

func newMachine(helper.MachineSpec) (helper.Machine, error) {
	return nil, errors.New("crew-vz needs macOS and Virtualization.framework")
}

func platformLimits() config.Limits { return config.Limits{} }
