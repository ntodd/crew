// Package vmctl is crew-vmctl: the root helper the unprivileged agent
// asks for everything that needs root on a Firecracker box (§10.8). It
// takes one JSON request per connection, from a fixed set of verbs whose
// arguments are UUIDs, booleans and bounded lease indexes. It never takes
// a path, a command or a free-form argument: every path is built here,
// and files the agent wrote are re-read and checked.
package vmctl

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
)

// MaxRequest is the largest request line accepted.
const MaxRequest = 4096

// Error codes in responses.
const (
	ErrBadRequest    = "bad_request"
	ErrUnknownVerb   = "unknown_verb"
	ErrInvalidConfig = "invalid_config"
	ErrAlreadyLaunch = "already_launched"
	ErrNotFound      = "not_found"
	ErrBusy          = "busy"
	ErrNftMismatch   = "nft_mismatch"
	ErrFailed        = "failed"
)

// Request is one request from the agent.
type Request struct {
	Verb       string `json:"verb"`
	VMID       string `json:"vm_id,omitempty"`
	LeaseIndex *int   `json:"lease_index,omitempty"`
	Force      *bool  `json:"force,omitempty"`
	BootID     string `json:"boot_id,omitempty"`

	// Lease is derived from LeaseIndex once it's checked.
	Lease Lease `json:"-"`
}

// Each verb's arguments: required, and allowed but optional.
type args struct{ required, optional []string }

var verbs = map[string]args{
	"start":         {required: []string{"vm_id"}},
	"stop":          {required: []string{"vm_id"}, optional: []string{"force"}},
	"status":        {required: []string{"vm_id"}},
	"list":          {},
	"tap-add":       {required: []string{"lease_index"}},
	"tap-del":       {required: []string{"lease_index"}},
	"pair-add":      {required: []string{"lease_index"}},
	"pair-del":      {required: []string{"lease_index"}},
	"nft-verify":    {},
	"reboot":        {required: []string{"boot_id"}, optional: []string{"force"}},
	"cleanup":       {required: []string{"vm_id"}},
	"restart-cache": {},
	"info":          {},
	"site4":         {},
}

// Error is an error with a response code.
type Error struct {
	Code   string
	Detail string
}

func (e *Error) Error() string { return e.Code + ": " + e.Detail }

func fail(code, format string, a ...any) error {
	return &Error{Code: code, Detail: fmt.Sprintf(format, a...)}
}

// ErrorCode is err's response code (ErrFailed when it has none).
func ErrorCode(err error) string {
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return ErrFailed
}

var uuidRe = regexp.MustCompile(`\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z`)

// IsUUID reports whether s is a lowercase, hyphenated UUID: the only
// form a vm_id or boot_id takes, and safe as a path element.
func IsUUID(s string) bool { return uuidRe.MatchString(s) }

// ParseRequest decodes and checks one request: a single JSON object with
// a known verb, exactly its arguments, each valid.
func ParseRequest(line []byte, net VMNet) (Request, error) {
	var r Request
	if len(line) > MaxRequest {
		return r, fail(ErrBadRequest, "request over %d bytes", MaxRequest)
	}
	dec := json.NewDecoder(bytes.NewReader(line))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&r); err != nil {
		return r, fail(ErrBadRequest, "%v", err)
	}
	if dec.More() {
		return r, fail(ErrBadRequest, "one request per connection")
	}
	spec, ok := verbs[r.Verb]
	if !ok {
		return r, fail(ErrUnknownVerb, "%q isn't a verb", r.Verb)
	}
	present := map[string]bool{
		"vm_id":       r.VMID != "",
		"lease_index": r.LeaseIndex != nil,
		"force":       r.Force != nil,
		"boot_id":     r.BootID != "",
	}
	allowed := map[string]bool{}
	for _, a := range spec.required {
		allowed[a] = true
		if !present[a] {
			return r, fail(ErrBadRequest, "%s needs %s", r.Verb, a)
		}
	}
	for _, a := range spec.optional {
		allowed[a] = true
	}
	for a, p := range present {
		if p && !allowed[a] {
			return r, fail(ErrBadRequest, "%s doesn't take %s", r.Verb, a)
		}
	}
	if r.VMID != "" && !IsUUID(r.VMID) {
		return r, fail(ErrBadRequest, "vm_id must be a lowercase UUID")
	}
	if r.BootID != "" && !IsUUID(r.BootID) {
		return r, fail(ErrBadRequest, "boot_id must be a lowercase UUID")
	}
	if r.LeaseIndex != nil {
		l, err := net.Lease(*r.LeaseIndex)
		if err != nil {
			return r, fail(ErrBadRequest, "%v", err)
		}
		r.Lease = l
	}
	return r, nil
}

// IsForce is the request's force flag (false when absent).
func (r Request) IsForce() bool { return r.Force != nil && *r.Force }
