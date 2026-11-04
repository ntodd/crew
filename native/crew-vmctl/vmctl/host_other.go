//go:build !linux

package vmctl

import (
	"context"
	"errors"

	"github.com/ntodd/crew/native/crew-vmctl/ruleset"
)

// SafePath is the only PATH crew-vmctl and its children see.
const SafePath = "/usr/sbin:/usr/bin:/sbin:/bin"

var errLinux = errors.New("crew-vmctl only runs on Linux")

type otherSys struct{}

// NewSys is the host; crew-vmctl only does anything on Linux. This lets
// the verbs' logic build and be tested elsewhere.
func NewSys(Paths) Sys { return otherSys{} }

func (otherSys) Run(context.Context, []byte, ...string) ([]byte, error) { return nil, errLinux }
func (otherSys) ReadAgentFile(string, string) ([]byte, error)           { return nil, errLinux }
func (otherSys) ReadFile(string, int64) ([]byte, error)                 { return nil, errLinux }
func (otherSys) WriteFile(string, []byte) error                         { return errLinux }
func (otherSys) CreateFile(string, []byte) error                        { return errLinux }
func (otherSys) WriteState(string, []byte) error                        { return errLinux }
func (otherSys) Exists(string) bool                                     { return false }
func (otherSys) Glob(string) []string                                   { return nil }
func (otherSys) PrepareJail(Jail) error                                 { return errLinux }
func (otherSys) RemoveJail(string, Peer) error                          { return errLinux }
func (otherSys) Reference(string) (ruleset.Listing, error)              { return ruleset.Listing{}, errLinux }

// PeerOf is the credentials of the socket's other end.
func PeerOf(int) (Peer, error) { return Peer{}, errLinux }
