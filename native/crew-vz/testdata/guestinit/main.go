//go:build linux

// guestinit is /init in the crew-vz integration-test guest. It runs the
// in-guest half of the test and powers off. Modes (crewtest.mode= on the
// kernel command line):
//
//	net    (default) reach the internet over TCP, fail to reach blocked
//	       addresses, talk to 10.199.0.1:7777 (the test's guest.sock),
//	       measure throughput, report, power off.
//	wait   say READY on 10.199.0.1:7777, then wait for the power button
//	       (requestStop) and power off.
//	flood  write crewtest.flood_mib MiB to the console and power off.
//	cache  download from 10.199.0.1:80 (the cache VM route) and report.
//	crew   (the default when crew.api is set) the guest API, as a job VM
//	       does: see crew.go.
//
// The protocol on 10.199.0.1:7777 is line-based, one connection per
// exchange: "HELLO <vm>", "READY <vm>", "DOWNLOAD <n>", "UPLOAD <n>",
// "REPORT <json>" (answered with "BYE").
package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const api = "10.199.0.1:7777"

var cmdline = map[string]string{}

func logf(format string, args ...any) {
	fmt.Fprintf(os.Stdout, "crewtest: "+format+"\n", args...)
}

func main() {
	mounts()
	readCmdline()
	logf("init up, kernel uptime %.3fs", uptime())
	if v := cmdline["crewtest.mtu"]; v != "" {
		if mtu, _ := strconv.Atoi(v); mtu > 0 {
			if err := setMTU("eth0", mtu); err != nil {
				logf("set mtu: %v", err)
			}
		}
	}
	if b, err := os.ReadFile("/sys/class/net/eth0/mtu"); err == nil {
		logf("eth0 mtu %s", strings.TrimSpace(string(b)))
	}
	var err error
	mode := cmdline["crewtest.mode"]
	if mode == "" && cmdline["crew.api"] != "" {
		mode = "crew"
	}
	switch mode {
	case "crew":
		err = crewMode()
	case "wait":
		err = waitMode()
	case "flood":
		err = floodMode()
	case "cache":
		err = cacheMode()
	default:
		err = netMode()
	}
	if err != nil {
		logf("error: %v", err)
	}
	logf("powering off")
	syscall.Sync()
	syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
	select {}
}

func mounts() {
	syscall.Mount("proc", "/proc", "proc", 0, "")
	syscall.Mount("sysfs", "/sys", "sysfs", 0, "")
	syscall.Mount("devtmpfs", "/dev", "devtmpfs", 0, "") // EBUSY if the kernel did it
	syscall.Mount("tmpfs", "/tmp", "tmpfs", 0, "")
}

func readCmdline() {
	b, _ := os.ReadFile("/proc/cmdline")
	for _, f := range strings.Fields(string(b)) {
		k, v, _ := strings.Cut(f, "=")
		cmdline[k] = v
	}
}

func uptime() float64 {
	b, _ := os.ReadFile("/proc/uptime")
	f := strings.Fields(string(b))
	if len(f) == 0 {
		return -1
	}
	v, _ := strconv.ParseFloat(f[0], 64)
	return v
}

func vmID() string { return cmdline["crew.vm"] }

// exchange sends one line to the guest API and reads one line back.
func exchange(line string) (string, error) {
	c, err := net.DialTimeout("tcp4", api, 5*time.Second)
	if err != nil {
		return "", err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(30 * time.Second))
	if _, err := fmt.Fprintf(c, "%s\n", line); err != nil {
		return "", err
	}
	reply, err := bufio.NewReader(c).ReadString('\n')
	return strings.TrimSpace(reply), err
}

type probe struct {
	Target string  `json:"target"`
	OK     bool    `json:"ok"`
	Err    string  `json:"err,omitempty"`
	Ms     float64 `json:"ms"`
}

type report struct {
	VM              string             `json:"vm"`
	UptimeAtInit    float64            `json:"uptime_at_init_s"`
	UptimeAtHello   float64            `json:"uptime_at_hello_s"`
	Hello           string             `json:"hello"`
	DNS             probe              `json:"dns"`
	Internet        []probe            `json:"internet"`
	BlockedTCP      []probe            `json:"blocked_tcp"`
	BlockedUDP      []probe            `json:"blocked_udp"`
	ServiceOther    []probe            `json:"service_other"`
	PingService     probe              `json:"ping_service"`
	PingInternet    probe              `json:"ping_internet"`
	ARPGateway      probe              `json:"arp_gateway"`
	ARPOther        []probe            `json:"arp_other"`
	IPv6            probe              `json:"ipv6"`
	LocalDownload   map[string]float64 `json:"local_download_mbps,omitempty"`
	LocalUpload     map[string]float64 `json:"local_upload_mbps,omitempty"`
	CacheDownload   map[string]float64 `json:"cache_download_mbps,omitempty"`
	InternetDL      map[string]float64 `json:"internet_download_mbps,omitempty"`
	InternetDLError string             `json:"internet_download_error,omitempty"`
}

func timed(target string, fn func() error) probe {
	start := time.Now()
	err := fn()
	p := probe{Target: target, OK: err == nil, Ms: float64(time.Since(start).Microseconds()) / 1000}
	if err != nil {
		p.Err = err.Error()
	}
	return p
}

func dialTCP(target string) error {
	c, err := net.DialTimeout("tcp4", target, 5*time.Second)
	if err == nil {
		c.Close()
	}
	return err
}

// udpRefused sends a datagram on a connected socket and waits for the
// ICMP port unreachable to surface as ECONNREFUSED.
func udpRefused(target string) error {
	c, err := net.Dial("udp4", target)
	if err != nil {
		return err
	}
	defer c.Close()
	c.Write([]byte("crewtest"))
	c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, err = c.Read(make([]byte, 512))
	if err == nil {
		return errors.New("got a reply")
	}
	return err
}

func netMode() error {
	r := report{VM: vmID(), UptimeAtInit: uptime()}
	hello, err := exchange("HELLO " + vmID())
	if err != nil {
		return fmt.Errorf("guest API: %w", err)
	}
	r.Hello, r.UptimeAtHello = hello, uptime()
	logf("guest API answered %q at uptime %.3fs", hello, r.UptimeAtHello)

	r.DNS = timed("dns example.com", func() error {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		addrs, err := (&net.Resolver{PreferGo: true}).LookupHost(ctx, "example.com")
		if err == nil && len(addrs) == 0 {
			err = errors.New("no addresses")
		}
		return err
	})
	for _, t := range []string{"1.1.1.1:443", "8.8.8.8:53", "example.com:80"} {
		r.Internet = append(r.Internet, timed(t, func() error { return dialTCP(t) }))
	}
	for _, t := range []string{"10.0.0.1:80", "192.168.1.1:80", "169.254.169.254:80", "10.200.0.1:22", "172.16.0.1:443", "100.100.100.100:80"} {
		r.BlockedTCP = append(r.BlockedTCP, timed(t, func() error { return dialTCP(t) }))
	}
	for _, t := range []string{"192.168.1.1:53", "10.0.0.1:123"} {
		r.BlockedUDP = append(r.BlockedUDP, timed(t, func() error { return udpRefused(t) }))
	}
	for _, t := range []string{"10.199.0.1:22", "10.199.0.1:443"} {
		r.ServiceOther = append(r.ServiceOther, timed(t, func() error { return dialTCP(t) }))
	}
	r.PingService = timed("10.199.0.1", func() error { return ping("10.199.0.1") })
	r.PingInternet = timed("1.1.1.1", func() error { return ping("1.1.1.1") })
	r.ARPGateway = timed("10.200.0.1", func() error { return arping("10.200.0.1") })
	for _, t := range []string{"10.200.0.3", "10.199.0.1", "10.200.0.5"} {
		r.ARPOther = append(r.ARPOther, timed(t, func() error { return arping(t) }))
	}
	r.IPv6 = timed("[2606:4700:4700::1111]:443", func() error {
		c, err := net.DialTimeout("tcp6", "[2606:4700:4700::1111]:443", 3*time.Second)
		if err == nil {
			c.Close()
		}
		return err
	})

	if cmdline["crewtest.quick"] != "" {
		return sendReport(r)
	}
	r.LocalDownload = map[string]float64{}
	r.LocalUpload = map[string]float64{}
	for _, mib := range []int{256, 1024} {
		if v, err := localDownload(mib << 20); err == nil {
			r.LocalDownload[fmt.Sprintf("%dMiB", mib)] = v
		} else {
			logf("local download: %v", err)
		}
	}
	if v, err := localUpload(512 << 20); err == nil {
		r.LocalUpload["512MiB"] = v
	} else {
		logf("local upload: %v", err)
	}
	if url := cmdline["crewtest.dl"]; url != "" {
		v, n, err := internetDownload(url)
		if err != nil {
			r.InternetDLError = err.Error()
		} else {
			r.InternetDL = map[string]float64{fmt.Sprintf("%dMiB", n>>20): v}
		}
	}

	return sendReport(r)
}

// cacheMode only measures the cache path: HTTP to 10.199.0.1:80, which the
// helper forwards to cache_addr.
func cacheMode() error {
	r := report{VM: vmID(), UptimeAtInit: uptime()}
	if _, err := exchange("HELLO " + vmID()); err != nil {
		return fmt.Errorf("guest API: %w", err)
	}
	r.CacheDownload = map[string]float64{}
	for _, mib := range []int{256, 1024, 2048} {
		v, _, err := internetDownload(fmt.Sprintf("http://10.199.0.1/bytes/%d", mib<<20))
		if err != nil {
			logf("cache download: %v", err)
			continue
		}
		r.CacheDownload[fmt.Sprintf("%dMiB", mib)] = v
	}
	return sendReport(r)
}

func sendReport(r report) error {
	b, _ := json.Marshal(r)
	logf("report %s", b)
	bye, err := exchange("REPORT " + string(b))
	if err != nil {
		return fmt.Errorf("report: %w", err)
	}
	logf("test said %q", bye)
	return nil
}

func mbps(n int64, d time.Duration) float64 { return float64(n) * 8 / d.Seconds() / 1e6 }

func localDownload(n int) (float64, error) {
	c, err := net.DialTimeout("tcp4", api, 5*time.Second)
	if err != nil {
		return 0, err
	}
	defer c.Close()
	fmt.Fprintf(c, "DOWNLOAD %d\n", n)
	start := time.Now()
	got, err := io.Copy(io.Discard, c)
	if err != nil {
		return 0, err
	}
	if got != int64(n) {
		return 0, fmt.Errorf("got %d of %d bytes", got, n)
	}
	return mbps(got, time.Since(start)), nil
}

func localUpload(n int) (float64, error) {
	c, err := net.DialTimeout("tcp4", api, 5*time.Second)
	if err != nil {
		return 0, err
	}
	defer c.Close()
	fmt.Fprintf(c, "UPLOAD %d\n", n)
	buf := make([]byte, 256<<10)
	start := time.Now()
	for sent := 0; sent < n; {
		k, err := c.Write(buf[:min(len(buf), n-sent)])
		if err != nil {
			return 0, err
		}
		sent += k
	}
	reply, err := bufio.NewReader(c).ReadString('\n')
	if err != nil || strings.TrimSpace(reply) != "OK" {
		return 0, fmt.Errorf("upload reply %q: %v", reply, err)
	}
	return mbps(int64(n), time.Since(start)), nil
}

func internetDownload(url string) (float64, int64, error) {
	tr := &http.Transport{
		// The guest has no CA bundle (and maybe no clock); this is a
		// throughput probe, not a trust decision.
		TLSClientConfig:    &tls.Config{InsecureSkipVerify: true},
		DisableCompression: true,
	}
	client := &http.Client{Transport: tr, Timeout: 120 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return 0, 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return 0, 0, fmt.Errorf("status %s", resp.Status)
	}
	start := time.Now()
	n, err := io.Copy(io.Discard, resp.Body)
	if err != nil {
		return 0, n, err
	}
	return mbps(n, time.Since(start)), n, nil
}

// ping sends one ICMP echo and waits a second for the reply.
func ping(dst string) error {
	c, err := net.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		return err
	}
	defer c.Close()
	msg := []byte{8, 0, 0, 0, 0x12, 0x34, 0, 1, 'c', 'r', 'e', 'w'}
	cs := csum(msg)
	msg[2], msg[3] = byte(cs>>8), byte(cs)
	if _, err := c.WriteTo(msg, &net.IPAddr{IP: net.ParseIP(dst)}); err != nil {
		return err
	}
	c.SetReadDeadline(time.Now().Add(time.Second))
	buf := make([]byte, 1500)
	for {
		n, from, err := c.ReadFrom(buf)
		if err != nil {
			return err
		}
		if from.String() == dst && n >= 8 && buf[0] == 0 && buf[4] == 0x12 && buf[5] == 0x34 {
			return nil
		}
	}
}

func csum(b []byte) uint16 {
	var s uint32
	for i := 0; i+1 < len(b); i += 2 {
		s += uint32(b[i])<<8 | uint32(b[i+1])
	}
	if len(b)%2 == 1 {
		s += uint32(b[len(b)-1]) << 8
	}
	for s>>16 != 0 {
		s = s&0xffff + s>>16
	}
	return ^uint16(s)
}

func htons(v uint16) uint16 { return v<<8 | v>>8 }

// arping sends one raw ARP request on eth0 and waits a second for a reply
// from target.
func arping(target string) error {
	ifc, err := net.InterfaceByName("eth0")
	if err != nil {
		return err
	}
	addrs, _ := ifc.Addrs()
	var src net.IP
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil {
			src = ipn.IP.To4()
		}
	}
	if src == nil {
		return errors.New("eth0 has no IPv4 address")
	}
	fd, err := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_RAW, int(htons(syscall.ETH_P_ARP)))
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	ll := &syscall.SockaddrLinklayer{Protocol: htons(syscall.ETH_P_ARP), Ifindex: ifc.Index}
	if err := syscall.Bind(fd, ll); err != nil {
		return err
	}
	tv := syscall.Timeval{Sec: 0, Usec: 200_000}
	syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv)
	tip := net.ParseIP(target).To4()
	f := make([]byte, 42)
	copy(f[0:6], []byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff})
	copy(f[6:12], ifc.HardwareAddr)
	binary.BigEndian.PutUint16(f[12:14], 0x0806)
	a := f[14:]
	binary.BigEndian.PutUint16(a[0:2], 1)
	binary.BigEndian.PutUint16(a[2:4], 0x0800)
	a[4], a[5] = 6, 4
	binary.BigEndian.PutUint16(a[6:8], 1)
	copy(a[8:14], ifc.HardwareAddr)
	copy(a[14:18], src)
	copy(a[24:28], tip)
	to := &syscall.SockaddrLinklayer{Ifindex: ifc.Index, Halen: 6, Protocol: htons(syscall.ETH_P_ARP)}
	copy(to.Addr[:], f[0:6])
	if err := syscall.Sendto(fd, f, 0, to); err != nil {
		return err
	}
	deadline := time.Now().Add(time.Second)
	buf := make([]byte, 1500)
	for time.Now().Before(deadline) {
		n, _, err := syscall.Recvfrom(fd, buf, 0)
		if err != nil {
			continue // timeout tick
		}
		if n >= 42 && binary.BigEndian.Uint16(buf[20:22]) == 2 && net.IP(buf[28:32]).Equal(tip) {
			return nil
		}
	}
	return errors.New("no ARP reply")
}

func waitMode() error {
	// Open the input devices first so a press right after READY isn't lost.
	var fds []int
	for i := 0; i < 8; i++ {
		fd, err := syscall.Open(fmt.Sprintf("/dev/input/event%d", i), syscall.O_RDONLY, 0)
		if err == nil {
			fds = append(fds, fd)
		}
	}
	logf("watching %d input devices for the power button", len(fds))
	if r, err := exchange("READY " + vmID()); err != nil {
		logf("ready: %v", err)
	} else {
		logf("test said %q", r)
	}
	if len(fds) == 0 {
		return errors.New("no input devices: kernel lacks gpio-keys/evdev")
	}
	pressed := make(chan int, 1)
	for _, fd := range fds {
		go func(fd int) {
			ev := make([]byte, 24) // struct input_event on arm64
			for {
				if n, err := syscall.Read(fd, ev); err != nil || n != 24 {
					return
				}
				typ := binary.LittleEndian.Uint16(ev[16:18])
				code := binary.LittleEndian.Uint16(ev[18:20])
				val := int32(binary.LittleEndian.Uint32(ev[20:24]))
				if typ == 1 && code == 116 && val == 1 { // EV_KEY, KEY_POWER, down
					pressed <- fd
					return
				}
			}
		}(fd)
	}
	<-pressed
	logf("power button pressed")
	return nil
}

// setMTU is SIOCSIFMTU.
func setMTU(ifname string, mtu int) error {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	var ifr [40]byte
	copy(ifr[:16], ifname)
	binary.LittleEndian.PutUint32(ifr[16:20], uint32(mtu))
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), syscall.SIOCSIFMTU, uintptr(unsafe.Pointer(&ifr[0]))); e != 0 {
		return e
	}
	return nil
}

func floodMode() error {
	mib, _ := strconv.Atoi(cmdline["crewtest.flood_mib"])
	if mib <= 0 {
		mib = 20
	}
	line := []byte(strings.Repeat("crew console flood ", 6) + "\n")
	var written int
	for written < mib<<20 {
		n, err := os.Stdout.Write(line)
		if err != nil {
			return err
		}
		written += n
	}
	logf("flooded %d bytes", written)
	return nil
}
