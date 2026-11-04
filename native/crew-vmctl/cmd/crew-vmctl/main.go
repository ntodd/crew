// Command crew-vmctl is the Firecracker box's root helper (spec §10.8).
//
//	crew-vmctl serve           one request on stdin (crew-vmctl@.service, socket-activated)
//	crew-vmctl exited <vm_id>  a VM unit's ExecStopPost: record how it ended
//	crew-vmctl net-up          crew-net.service: crew0, the packet filter, site4
//	crew-vmctl site4           crew-net-site4.service: refill site4
//	crew-vmctl version
//
// Its settings come from its own units, never from the agent:
// --data-dir (default /srv/crew) and CREW_VM_NET (default 10.200.0.0/16).
// See native/crew-vmctl/README.md.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"time"

	"github.com/ntodd/crew/native/crew-vmctl/vmctl"
)

// version is set at build time (-ldflags "-X main.version=...").
var version = "dev"

const defaultVMNet = "10.200.0.0/16"

func usage() {
	fmt.Fprintln(os.Stderr, `usage: crew-vmctl [--data-dir DIR] serve | exited <vm_id> | net-up | site4 | version`)
}

func main() {
	// systemd's view of how a unit ended, for `exited`; then nothing of
	// the environment is kept.
	env := map[string]string{}
	for _, k := range []string{"SERVICE_RESULT", "EXIT_CODE", "EXIT_STATUS", "CREW_VM_NET"} {
		env[k] = os.Getenv(k)
	}
	os.Clearenv()
	_ = os.Setenv("PATH", vmctl.SafePath)

	fs := flag.NewFlagSet("crew-vmctl", flag.ContinueOnError)
	data := fs.String("data-dir", vmctl.DefaultData, "the data directory")
	if err := fs.Parse(os.Args[1:]); err != nil || fs.NArg() < 1 {
		usage()
		os.Exit(64)
	}
	cidr := env["CREW_VM_NET"]
	if cidr == "" {
		cidr = defaultVMNet
	}
	net, err := vmctl.ParseVMNet(cidr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "crew-vmctl:", err)
		os.Exit(78)
	}
	paths := vmctl.Paths{Data: *data}
	srv := &vmctl.Server{Paths: paths, Net: net, Sys: vmctl.NewSys(paths), Now: time.Now, Version: version}
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	args := fs.Args()

	if args[0] == "version" {
		fmt.Println("crew-vmctl", version)
		return
	}
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "crew-vmctl: runs as root, from its systemd units")
		os.Exit(77)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	switch {
	case args[0] == "serve" && len(args) == 1:
		os.Exit(serve(ctx, srv, net, log))
	case args[0] == "exited" && len(args) == 2:
		if err := srv.RecordExit(args[1], func(k string) string { return env[k] }); err != nil {
			log.Error("exited", "vm_id", args[1], "err", err)
			os.Exit(1)
		}
	case args[0] == "net-up" && len(args) == 1:
		if err := srv.NetUp(ctx); err != nil {
			log.Error("net-up", "err", err)
			os.Exit(1)
		}
		log.Info("net-up: crew0, inet crew and the connection cap are loaded")
	case args[0] == "site4" && len(args) == 1:
		if err := srv.RefreshSite4(ctx); err != nil {
			log.Error("site4", "err", err)
			os.Exit(1)
		}
	case args[0] == "nft-reference" && len(args) == 3 && args[1] == "--uplink":
		out, err := vmctl.NftReference(ctx, srv.Sys, args[2])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		_ = json.NewEncoder(os.Stdout).Encode(out)
	default:
		usage()
		os.Exit(64)
	}
}

// serve answers the one request on stdin, the connection systemd
// accepted (Accept=yes), and exits.
func serve(ctx context.Context, srv *vmctl.Server, net vmctl.VMNet, log *slog.Logger) int {
	peer, err := vmctl.PeerOf(0)
	if err != nil {
		log.Error("serve: stdin isn't a Unix socket", "err", err)
		return 1
	}
	line, err := readLine(os.Stdin, vmctl.MaxRequest+1)
	var resp vmctl.Response
	var r vmctl.Request
	if err == nil {
		r, err = vmctl.ParseRequest(line, net)
	}
	if err != nil {
		resp = vmctl.Response{Error: vmctl.ErrorCode(err), Detail: err.Error()}
	} else {
		resp = srv.Handle(ctx, r, peer)
	}
	log.Info("request", "verb", r.Verb, "vm_id", r.VMID, "uid", peer.UID, "ok", resp.OK, "error", resp.Error, "detail", resp.Detail)
	b, _ := json.Marshal(resp)
	if _, err := os.Stdout.Write(append(b, '\n')); err != nil {
		return 1
	}
	return 0
}

func readLine(r io.Reader, max int) ([]byte, error) {
	br := bufio.NewReaderSize(io.LimitReader(r, int64(max)), max)
	line, err := br.ReadSlice('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		if errors.Is(err, bufio.ErrBufferFull) {
			return nil, fmt.Errorf("request over %d bytes", max-1)
		}
		return nil, err
	}
	if len(line) >= max {
		return nil, fmt.Errorf("request over %d bytes", max-1)
	}
	return line, nil
}
