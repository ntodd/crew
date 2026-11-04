#!/usr/bin/python3 -I
"""Socket-level probes for the conformance check (docs/crew_spec.md §11.6).

Called only by /opt/crew/conformance/check, with arguments it has already
checked; each is parsed again here (ipaddress, int) and never evaluated.

  probe.py tcp <ip> <port> <timeout_s> [<source ip>]
      connected | refused | timeout | unreachable | error:<errno name>
  probe.py udp-dns <ip> <port> <timeout_s>
      answered | timeout | refused | unreachable | error:<errno name>
  probe.py conns <ip> <port> <count> <timeout_s>
      how many of <count> TCP connections were established, held at once
  probe.py loop6
      ok when a TCP connection to a listener on [::1] works
  probe.py listen <port> <seconds>
      accepts and closes connections on 0.0.0.0:<port> for <seconds>
  probe.py console <mib> <seconds>
      writes to /dev/console; prints "<bytes written> <seconds taken>"
  probe.py flood <api> <path> <seconds> <threads> <body kind> [<bytes>]
      POSTs as fast as it can; prints {"status": count, ...} as JSON.
      The token is read from /proc/cmdline.
"""

import errno
import http.client
import ipaddress
import json
import os
import resource
import select
import socket
import struct
import sys
import threading
import time
import urllib.parse


def outcome(err):
    if err is None:
        return "connected"
    if isinstance(err, socket.timeout):
        return "timeout"
    code = getattr(err, "errno", None)
    if code == errno.ECONNREFUSED:
        return "refused"
    if code in (errno.EHOSTUNREACH, errno.ENETUNREACH):
        return "unreachable"
    if code == errno.ETIMEDOUT:
        return "timeout"
    return "error:" + (errno.errorcode.get(code, str(code)) if code else type(err).__name__)


def tcp(ip, port, timeout, source=None):
    addr = ipaddress.ip_address(ip)
    family = socket.AF_INET6 if addr.version == 6 else socket.AF_INET
    s = socket.socket(family, socket.SOCK_STREAM)
    s.settimeout(float(timeout))
    try:
        if source:
            s.bind((str(ipaddress.ip_address(source)), 0))
        s.connect((str(addr), int(port)))
        return outcome(None)
    except OSError as e:
        return outcome(e)
    finally:
        s.close()


def dns_query(name="github.com"):
    q = struct.pack(">HHHHHH", os.getpid() & 0xFFFF, 0x0100, 1, 0, 0, 0)
    for label in name.split("."):
        q += bytes([len(label)]) + label.encode()
    return q + b"\x00" + struct.pack(">HH", 1, 1)


def udp_dns(ip, port, timeout):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(float(timeout))
    try:
        s.connect((str(ipaddress.ip_address(ip)), int(port)))
        s.send(dns_query())
        s.recv(4096)
        return "answered"
    except OSError as e:
        r = outcome(e)
        return "timeout" if r == "timeout" else r
    finally:
        s.close()


def conns(ip, port, count, timeout):
    count = int(count)
    resource.setrlimit(resource.RLIMIT_NOFILE, (count + 256, count + 256))
    target = (str(ipaddress.ip_address(ip)), int(port))
    pending, done, socks = {}, 0, []
    for _ in range(count):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setblocking(False)
        s.connect_ex(target)
        pending[s.fileno()] = s
        socks.append(s)
    poller = select.poll()
    for fd in pending:
        poller.register(fd, select.POLLOUT)
    deadline = time.monotonic() + float(timeout)
    while pending and time.monotonic() < deadline:
        for fd, _ev in poller.poll(200):
            s = pending.pop(fd, None)
            if s is None:
                continue
            poller.unregister(fd)
            if s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR) == 0:
                done += 1
    time.sleep(2)
    for s in socks:
        s.close()
    return str(done)


def loop6():
    srv = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    srv.bind(("::1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]
    threading.Thread(target=lambda: srv.accept()[0].close(), daemon=True).start()
    result = tcp("::1", port, 3)
    srv.close()
    return "ok" if result == "connected" else result


def listen(port, seconds):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", int(port)))
    srv.listen(64)
    srv.settimeout(1)
    end = time.monotonic() + float(seconds)
    while time.monotonic() < end:
        try:
            srv.accept()[0].close()
        except socket.timeout:
            pass
    return "done"


def console(mib, seconds):
    """Writes up to <mib> MiB of lines to /dev/console, for at most <seconds>."""
    line = b"crew-conformance console flood " + b"x" * 96 + b"\n"
    chunk = line * (65536 // len(line))
    want, wrote = int(mib) * 1048576, 0
    start = time.monotonic()
    end = start + float(seconds)
    fd = os.open("/dev/console", os.O_WRONLY | os.O_NOCTTY)
    try:
        while wrote < want and time.monotonic() < end:
            wrote += os.write(fd, chunk[: want - wrote])
    finally:
        os.close(fd)
    return "%d %.1f" % (wrote, time.monotonic() - start)


def token():
    with open("/proc/cmdline") as f:
        for arg in f.read().split():
            if arg.startswith("crew.token="):
                return arg.split("=", 1)[1]
    raise SystemExit("no crew.token on the command line")


def body(kind, size):
    now = int(time.time() * 1000)
    if kind == "log":
        line = json.dumps({"t": now, "step_ref": "flood", "text": "x" * 1000}) + "\n"
        return (line * max(1, size // len(line))).encode(), "application/x-ndjson"
    if kind == "steps":
        steps = [{"ref": "s%d" % i, "name": "flood", "number": i, "status": "in_progress"} for i in range(5)]
        return json.dumps({"steps": steps}).encode(), "application/json"
    if kind == "state":
        return json.dumps({"state": "job_started", "at": now, "detail": "flood"}).encode(), "application/json"
    raise SystemExit("unknown body kind")


def flood(api, path, seconds, threads, kind, size=65536):
    url = urllib.parse.urlparse(api)
    data, ctype = body(kind, int(size))
    headers = {"Authorization": "Bearer " + token(), "Content-Type": ctype}
    counts, lock = {}, threading.Lock()
    end = time.monotonic() + float(seconds)

    def worker():
        while time.monotonic() < end:
            try:
                c = http.client.HTTPConnection(url.hostname, url.port, timeout=5)
                c.request("POST", path, body=data, headers=headers)
                status = str(c.getresponse().status)
                c.close()
            except OSError as e:
                status = outcome(e)
            with lock:
                counts[status] = counts.get(status, 0) + 1

    ts = [threading.Thread(target=worker) for _ in range(int(threads))]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    return json.dumps(counts, sort_keys=True)


COMMANDS = {
    "tcp": tcp,
    "udp-dns": udp_dns,
    "conns": conns,
    "loop6": loop6,
    "listen": listen,
    "console": console,
    "flood": flood,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        raise SystemExit(__doc__)
    print(COMMANDS[sys.argv[1]](*sys.argv[2:]))
