// Command crew-vz is the vz driver's macOS helper (§11.4):
//
//	crew-vz run --config <data>/vms/<id>/vz.json --deadline <unix>
//	crew-vz daemon [--socket PATH] [--data-dir DIR]
//	crew-vz version
//
// See native/crew-vz/README.md.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/ntodd/crew/native/crew-vz/config"
	"github.com/ntodd/crew/native/crew-vz/daemon"
	"github.com/ntodd/crew/native/crew-vz/helper"
)

// version is set at build time (-ldflags "-X main.version=...").
var version = "dev"

func usage() {
	fmt.Fprintf(os.Stderr, `usage:
  crew-vz run --config <data>/vms/<id>/vz.json --deadline <unix> [--data-dir DIR] [--sandbox PROFILE]
  crew-vz daemon [--socket PATH] [--data-dir DIR] [--sandbox PROFILE]
  crew-vz version
`)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(64)
	}
	switch os.Args[1] {
	case "run":
		os.Exit(runCmd(os.Args[2:]))
	case "daemon":
		os.Exit(daemonCmd(os.Args[2:]))
	case "version", "--version":
		fmt.Println("crew-vz", version)
	default:
		usage()
		os.Exit(64)
	}
}

func logger(verbose bool) *slog.Logger {
	lvl := slog.LevelInfo
	if verbose {
		lvl = slog.LevelDebug
	}
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: lvl}))
}

// limitFlags registers the per-VM limit flags; zero means the host default.
func limitFlags(fs *flag.FlagSet) (*int, *int) {
	return fs.Int("max-vcpus", 0, "largest vcpus a VM may ask for (default: host cores, capped by VZ)"),
		fs.Int("max-memory-mib", 0, "largest memory_mib a VM may ask for (default: host memory - 2 GiB, capped by VZ)")
}

func limits(maxVCPUs, maxMemMiB int) config.Limits {
	l := platformLimits()
	if maxVCPUs > 0 && maxVCPUs < l.MaxVCPUs {
		l.MaxVCPUs = maxVCPUs
	}
	if maxMemMiB > 0 && maxMemMiB < l.MaxMemoryMiB {
		l.MaxMemoryMiB = maxMemMiB
	}
	return l
}

func runCmd(args []string) int {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	cfgPath := fs.String("config", "", "path to vms/<id>/vz.json")
	deadline := fs.Int64("deadline", 0, "unix time at which the VM is killed")
	dataDir := fs.String("data-dir", "", "data dir (default: derived from --config)")
	sandbox := fs.String("sandbox", "", "re-exec under sandbox-exec with this profile")
	verbose := fs.Bool("v", false, "debug logging")
	maxVCPUs, maxMem := limitFlags(fs)
	if err := fs.Parse(args); err != nil {
		return 64
	}
	if *cfgPath == "" || *deadline == 0 {
		fmt.Fprintln(os.Stderr, "crew-vz run: --config and --deadline are required")
		return 64
	}
	abs, err := filepath.Abs(*cfgPath)
	if err != nil {
		return 64
	}
	if *sandbox != "" && os.Getenv("CREW_VZ_SANDBOXED") == "" {
		return reexecSandboxed(*sandbox, abs, args)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer stop()
	return helper.Run(ctx, helper.Options{
		ConfigPath: abs,
		DataDir:    *dataDir,
		Deadline:   time.Unix(*deadline, 0),
		Limits:     limits(*maxVCPUs, *maxMem),
		NewMachine: newMachine,
		Logger:     logger(*verbose),
	})
}

// reexecSandboxed runs this same command under sandbox-exec (for trying
// the profile by hand; crew-vzd wraps helpers itself).
func reexecSandboxed(profile, cfgPath string, args []string) int {
	cfg, err := config.Load(cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	exe, err := os.Executable()
	if err != nil {
		return 1
	}
	argv := append([]string{daemon.SandboxExec}, daemon.SandboxArgs(profile, exe, cfg)...)
	argv = append(argv, exe, "run")
	argv = append(argv, args...)
	env := append(os.Environ(), "CREW_VZ_SANDBOXED=1")
	err = syscall.Exec(daemon.SandboxExec, argv, env)
	fmt.Fprintln(os.Stderr, "exec sandbox-exec:", err)
	return 1
}

func daemonCmd(args []string) int {
	fs := flag.NewFlagSet("daemon", flag.ContinueOnError)
	sock := fs.String("socket", daemon.DefaultSocket, "control socket")
	dataDir := fs.String("data-dir", daemon.DefaultDataDir, "data dir (holds vms/)")
	sandbox := fs.String("sandbox", "", "run helpers under sandbox-exec with this profile")
	group := fs.String("socket-group", "", "numeric gid for the control socket")
	verbose := fs.Bool("v", false, "debug logging")
	maxVCPUs, maxMem := limitFlags(fs)
	if err := fs.Parse(args); err != nil {
		return 64
	}
	gid := -1
	if *group != "" {
		g, err := strconv.Atoi(*group)
		if err != nil {
			fmt.Fprintln(os.Stderr, "--socket-group must be a numeric gid")
			return 64
		}
		gid = g
	}
	if *sandbox != "" {
		p, err := filepath.Abs(*sandbox)
		if err != nil {
			return 64
		}
		*sandbox = p
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	err := daemon.Run(ctx, daemon.Options{
		SocketPath:     *sock,
		DataDir:        *dataDir,
		Limits:         limits(*maxVCPUs, *maxMem),
		SandboxProfile: *sandbox,
		SocketGID:      gid,
		Logger:         logger(*verbose),
	})
	if err != nil && !errors.Is(err, context.Canceled) {
		fmt.Fprintln(os.Stderr, "crew-vz daemon:", err)
		return 1
	}
	return 0
}
