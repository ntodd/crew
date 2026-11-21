# Run a Crew worker alongside Foreman on Linux

A native worker runs one Cloud Hypervisor process per job using the physical machine’s KVM. The control plane can run elsewhere. Crew’s x86-64 release build takes the static VMM and checksum from Foreman’s pinned release manifest. Each product owns its service identities, VM disks, network interfaces and updates.

## Install on Debian or Ubuntu

Use Debian 13 or Ubuntu 24.04 on x86-64. The package requires glibc 2.39 or later. Install the matching control-plane release first and select its x64 guest image. Use the guest image built with this change. Its kernel has the PVH entry point and its guest service powers off Cloud Hypervisor when a job ends.

1. Provide an empty dedicated XFS filesystem mounted persistently at `/srv/crew`, with reflinks and project quotas enabled. Crew takes ownership of that filesystem. Enrollment checks the mount and never formats a disk. Reserve `10.199.0.1`, `10.200.0.0/16`, UID/GID 200001–216383, and the service names `_crewagent`, `crewvm` and `crewcache`. The host needs KVM, TUN, systemd and cgroup v2. Foreman’s default guest address pool is `10.250.0.0/16`.
2. Download `crew-worker_VERSION_amd64.deb`, its `.sha256` and its `.sig` from the same GitHub release. From a trusted Crew checkout, verify the files and install the package. Replace `VERSION` with the release number.

   ```sh
   packaging/debian/verify.sh ./crew-worker_VERSION_amd64.deb packaging/release/release-key.pub
   sudo apt install ./crew-worker_VERSION_amd64.deb
   ```

3. In **Boxes → Add box**, choose **Debian or Ubuntu on x86-64**. Run the displayed enrollment command and enter the join token at the prompt. Set the total budget for job VMs with `--cpus` and `--memory-mib`. For example, this reserves a maximum of eight CPUs’ time and 16 GiB for jobs on the shared machine.

   ```sh
   sudo crew-worker-enroll https://crew.example.org build01 --cpus 8 --memory-mib 16384
   ```

The defaults are two CPUs and 8192 MiB. The kernel enforces aggregate job limits through `crew-jobs.slice`. Leave capacity for Debian, Foreman, the Crew agent and its cache. Enable IPv4 forwarding in the host's persistent network configuration before enrollment and use a kernel with Landlock enabled. Crew needs TCP ports 53, 80, 443 and 7777 and UDP port 53 on `10.199.0.1`, plus TCP port 7780 on loopback for authenticated cache management. Crew installs its own nftables table. Forwarded traffic between unrelated interfaces passes through Crew’s chain. The host’s remaining firewall rules still apply, including rules that may block guest egress. Crew leaves host reboots to the operator.

The agent and cache come from the control plane’s signed release set. APT manages the enrollment package and service definitions. Crew’s existing Deployment workflow manages signed runtime updates and rollback. To diagnose enrollment, use `journalctl -u crew-agent -u crew-net -u crew-cache`. Rerun enrollment with the same box name and budget to resume an interrupted install. An expired token can be replaced with a new token from Add box.

## Hardware acceptance

On a disposable x86-64 KVM test host, run the existing driver conformance suite with the native backend and a freshly built guest kernel and root filesystem.

```sh
sudo CREW_REAL_IMAGE_DIR=/path/to/x64-image native/crew-vmctl/kvm/run.sh --cloud-hypervisor
```

The harness provisions test units, networking and storage on the test host. For shared-host acceptance, enroll a worker through the package on a separate test machine already running Foreman. Keep a Foreman environment active throughout. Run and cancel a GitHub Actions job, restart the agent during another job, and run concurrent jobs up to the configured budget. Verify Foreman retains network access while Crew reloads its rules and that completed jobs leave no VMMs or TAPs. Repeat after a host reboot and runtime upgrade.

Packaged worker acceptance on Debian and Ubuntu is tracked in [Crew #160](https://github.com/ntodd/crew/issues/160).
Existing Flatcar workers use Firecracker. For the Flatcar migration and the remaining worker types, see [Crew #143](https://github.com/ntodd/crew/issues/143) and the [migration tracker](https://github.com/ntodd/crew/issues/159).
