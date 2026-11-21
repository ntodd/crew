#!/usr/bin/python3
"""Enroll an existing Debian or Ubuntu host using the installed release bootstrap."""
import argparse
import base64
import fcntl
import getpass
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shlex
import socket
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit

LIB = Path("/usr/lib/crew-worker")
ETC = Path("/etc/crew-box")
DATA = Path("/srv/crew")
UNITS = Path("/etc/systemd/system")
VM_IDS = range(200001, 216384)


def run(*args):
    subprocess.run(args, check=True)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def write(path, contents, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".new")
    temp.write_text(contents)
    temp.chmod(mode)
    temp.replace(path)


def env_file(path, values):
    write(path, "".join(f"{key}={shlex.quote(value)}\n" for key, value in values.items()))


def require(ok, message):
    if not ok:
        sys.exit(message)


def check_identities():
    for database in ("passwd", "group"):
        for line in output("getent", database).splitlines():
            fields = line.split(":")
            ids = fields[2:4] if database == "passwd" else fields[2:3]
            require(all(int(value) not in VM_IDS for value in ids),
                    f"{database} entry {fields[0]} uses a Crew VM identity")
    for file in ("/etc/subuid", "/etc/subgid"):
        path = Path(file)
        for line in path.read_text().splitlines() if path.exists() else []:
            if not line.strip() or line.startswith("#"):
                continue
            _, first, count = line.rsplit(":", 2)
            require(int(first) >= VM_IDS.stop or int(first) + int(count) <= VM_IDS.start,
                    f"Crew's VM identity range overlaps {file}")


def check_listeners():
    # IP_FREEBIND lets Linux test the exact service address before crew0 exists.
    for kind, address, ports in (
        (socket.SOCK_STREAM, "10.199.0.1", (53, 80, 443, 7777)),
        (socket.SOCK_DGRAM, "10.199.0.1", (53,)),
        (socket.SOCK_STREAM, "127.0.0.1", (7780,)),
    ):
        for port in ports:
            with socket.socket(socket.AF_INET, kind) as sock:
                sock.setsockopt(socket.IPPROTO_IP, getattr(socket, "IP_FREEBIND", 15), 1)
                if kind == socket.SOCK_STREAM:
                    # A stopped listener can leave recently closed connections in TIME_WAIT.
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    sock.bind((address, port))
                    if kind == socket.SOCK_STREAM:
                        sock.listen(1)
                except OSError as err:
                    sys.exit(f"Crew cannot bind {address}:{port}: {err.strerror}")


def check_host(fresh):
    require(platform.machine() == "x86_64" and Path("/dev/kvm").is_char_device()
            and Path("/dev/net/tun").is_char_device(), "An x86-64 KVM host with TUN is required")
    require(os.path.ismount(DATA), "Mount a dedicated XFS filesystem at /srv/crew before enrollment")
    mount = output("findmnt", "-n", "-M", str(DATA), "-o", "FSTYPE,OPTIONS").split()
    require(mount[0] == "xfs" and {"prjquota", "pquota"} & set(mount[1].split(",")),
            "/srv/crew must be a dedicated XFS mount with project quotas")
    require("reflink=1" in output("xfs_info", str(DATA)), "Enable reflinks on Crew's volume")
    require(output("findmnt", "-n", "-M", str(DATA), "-o", "FSROOT") == "/",
            "/srv/crew must be the root of its own filesystem")
    require(not DATA.is_symlink() and DATA.stat().st_uid == 0 and not DATA.stat().st_mode & 0o022,
            "/srv/crew must be root-owned and writable only by root")
    controllers = Path("/sys/fs/cgroup/cgroup.controllers")
    require(controllers.is_file() and {"cpu", "memory"} <= set(controllers.read_text().split()),
            "Crew needs cgroup v2 with the CPU and memory controllers")
    require(Path("/run/systemd/system").is_dir(), "Systemd must be running on this host")
    lsm = Path("/sys/kernel/security/lsm")
    require(lsm.is_file() and "landlock" in lsm.read_text().strip().split(","),
            "Enable Landlock on the worker kernel for VM filesystem isolation")
    require(Path("/proc/sys/net/ipv4/ip_forward").read_text().strip() == "1",
            "Enable IPv4 forwarding in the host's network configuration before enrollment")
    check_identities()
    if fresh:
        require(not any(DATA.iterdir()), "/srv/crew already holds data from another install")
        require(not ETC.exists(), "/etc/crew-box already exists; inspect the existing installation")
        ranges = [ipaddress.ip_network(net) for net in ("10.199.0.1/32", "10.200.0.0/16")]
        for route in json.loads(output("ip", "-j", "-4", "route", "show", "table", "all")):
            dst = route.get("dst", "default")
            if dst != "default" and any(ipaddress.ip_network(dst, strict=False).overlaps(n) for n in ranges):
                sys.exit(f"Crew addresses overlap the host route {dst}")
        links = json.loads(output("ip", "-j", "link"))
        require(not any(i["ifname"] == "crew0" or i["ifname"].startswith("crewt") for i in links),
                "A Crew network interface already exists")
        tables = json.loads(output("nft", "-j", "list", "tables"))["nftables"]
        require(not any(t.get("table", {}).get("name") == "crew" and
                        t["table"]["family"] == "inet" for t in tables),
                "The host already owns the inet crew firewall table")
        mangle = output("iptables-nft-save", "-t", "mangle")
        require(not any(line.startswith(":CREW-CONNLIMIT ") for line in mangle.splitlines()),
                "The host already owns the CREW-CONNLIMIT firewall chain")
        # Even an unconfigured slice has LoadState=loaded. Check unit files,
        # drop-ins and activity, resolving the socket template as an instance.
        for unit in ("crew-jobs.slice", "crew-vmctl.socket", "crew-vmctl@preflight.service",
                     "crew-net.service", "crew-net-site4.service", "crew-net-site4.timer"):
            state = output("systemctl", "show", "-p", "ActiveState,FragmentPath,DropInPaths", unit)
            require(set(state.splitlines()) == {"ActiveState=inactive", "FragmentPath=", "DropInPaths="},
                    f"The host already has a {unit} unit")
        check_listeners()
        for name in ("_crewagent", "crewcache", "crewvm"):
            require(subprocess.run(["getent", "group", name], stdout=subprocess.DEVNULL).returncode == 2,
                    f"The group {name} already exists")
            require(subprocess.run(["getent", "passwd", name], stdout=subprocess.DEVNULL).returncode == 2,
                    f"The account {name} already exists")


def enroll(args):
    url = args.url.rstrip("/")
    require(re.fullmatch(r"https://[A-Za-z0-9.-]+(:[0-9]+)?", url), "Use the control plane's HTTPS origin")
    require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,38}[a-z0-9]|[a-z0-9]", args.name), "Invalid box name")
    require(args.cpus > 0 and args.memory_mib >= 4096, "Reserve at least 1 CPU and 4096 MiB for Crew")
    marker = ETC / "native-worker"
    settings = {"url": url, "name": args.name, "cpus": args.cpus, "memory_mib": args.memory_mib}
    fresh = not marker.exists()
    check_host(fresh)
    if not fresh:
        require(json.loads(marker.read_text()) == settings, "This host already has different Crew settings")
    version = (LIB / "version").read_text().strip()
    key = next(line for line in (LIB / "release-key.pub").read_text().splitlines() if not line.startswith("#") and line)
    identity = DATA / "agent/identity.json"
    token = "" if identity.exists() else getpass.getpass("Crew join token: ")
    require(not token or re.fullmatch(r"cj_[A-Za-z0-9_-]{43}", token), "Invalid join token")
    require(token or identity.exists(), "Enrollment needs a token")
    release = dict(CREW_VERSION=version, CREW_TARGET="linux-amd64", CREW_RELEASE_PUBLIC_KEY=key,
                   CREW_AGENT_SOCKET_URL=f"wss://{urlsplit(url).netloc}/agent/websocket")
    if not (DATA / "agent/current").exists():
        for component in ("agent", "cache"):
            asset = f"crew-{component}-{version}-linux-amd64.tar.gz"
            endpoint = f"{url}/agent/releases/{version}/linux-amd64/{asset}"
            prefix = "CREW_" + component.upper()
            release[prefix + "_URL"] = endpoint
            for suffix, field in ((".sha256", "_SHA256"), (".sig", "_SIG")):
                release[prefix + field] = output("curl", "-fsS", "--max-time", "30", endpoint + suffix).split()[0]

    if fresh:
        # Publish the marker and its directory together so a retry sees a complete record.
        with tempfile.TemporaryDirectory(dir=ETC.parent, prefix=".crew-enroll-") as tmp:
            write(Path(tmp) / marker.name, json.dumps(settings))
            Path(tmp).rename(ETC)
    for name in ("_crewagent", "crewcache", "crewvm"):
        if subprocess.run(["getent", "group", name], stdout=subprocess.DEVNULL).returncode:
            run("groupadd", "--system", name)
    for name in ("_crewagent", "crewcache"):
        if subprocess.run(["getent", "passwd", name], stdout=subprocess.DEVNULL).returncode:
            run("useradd", "--system", "--no-create-home", "--gid", name, "--shell", "/usr/sbin/nologin", name)
    for script in LIB.glob("*.sh"):
        (ETC / script.name).unlink(missing_ok=True)
        (ETC / script.name).symlink_to(script)
    raw_key = base64.b64decode(key, validate=True)
    public_der = bytes.fromhex("302a300506032b6570032100") + raw_key
    pem = base64.encodebytes(public_der).decode()
    write(ETC / "release-key.pem", f"-----BEGIN PUBLIC KEY-----\n{pem}-----END PUBLIC KEY-----\n")
    release["CREW_RELEASE_KEY_FINGERPRINT"] = "SHA256:" + base64.b64encode(hashlib.sha256(raw_key).digest()).decode().rstrip("=")
    env_file(ETC / "box.env", {"CREW_BOX_NAME": args.name, "CREW_BOX_TYPE": "linux-native"})
    if not (DATA / "agent/current").exists():
        env_file(ETC / "release.env", release)
    if token:
        env_file(ETC / "join.env", {"CREW_JOIN_TOKEN": token})
    env_file(ETC / "budget.env", {"CREW_WORKER_VCPUS": str(args.cpus),
                                  "CREW_WORKER_MEMORY_MIB": str(args.memory_mib)})
    # systemd reads this as root for both services. Keep the credential on retries.
    if not (ETC / "cache-auth.env").exists():
        env_file(ETC / "cache-auth.env", {"CREW_CACHE_MGMT_TOKEN": secrets.token_urlsafe(32)})
    write(UNITS / "crew-jobs.slice", "[Unit]\nDescription=Crew job VMs\n[Slice]\n"
          f"CPUQuota={100 * args.cpus}%\nMemoryMax={args.memory_mib}M\nMemorySwapMax=0\n", 0o644)
    run("systemctl", "daemon-reload")
    run("systemctl", "enable", "--now", "crew-quota.service")
    run("/bin/sh", ETC / "agent-install.sh")
    run("systemctl", "enable", "--now", "crew-root-units.service")
    run("systemctl", "enable", "--now", "crew-root-install.path", "crew-agent.service", "crew-cache.service")
    if token and not fresh and not identity.exists():
        run("systemctl", "restart", "crew-agent.service")
    for _ in range(90):
        if identity.is_file():
            (ETC / "join.env").unlink(missing_ok=True)
            print(f"{args.name} enrolled")
            return
        time.sleep(2)
    sys.exit("Agent has not enrolled. Inspect journalctl -u crew-agent and rerun with a valid token.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    parser.add_argument("name")
    parser.add_argument("--cpus", type=int, default=2)
    parser.add_argument("--memory-mib", type=int, default=8192)
    args = parser.parse_args()
    require(os.geteuid() == 0, "Run crew-worker-enroll as root")
    os.umask(0o077)
    with open("/run/crew-worker-enroll.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        enroll(args)
