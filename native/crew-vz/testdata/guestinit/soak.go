//go:build linux

package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// soakMode hunts for wedged flows (ntodd/crew hung jobs): until
// crewtest.soak_s runs out, crewtest.soak_workers workers download
// layer-sized objects through the cache route (10.199.0.1:80, on kept-alive
// connections, as containerd fetches), and, with crewtest.dl set, one more
// worker fetches that URL on a fresh connection every crewtest.dl_every_s
// (as setup-beam's tool-cache does). A download with no new byte for
// crewtest.soak_stall_s is reported to the test (STALL) and then waited on,
// up to crewtest.soak_give_up_s, to see whether it resumes, is reset by the
// helper's stall timeout, or stays stuck.
func soakMode() error {
	if _, err := exchange("HELLO " + vmID()); err != nil {
		return fmt.Errorf("guest API: %w", err)
	}
	num := func(k string, d int) int {
		if n, err := strconv.Atoi(cmdline[k]); err == nil && n > 0 {
			return n
		}
		return d
	}
	until := time.Now().Add(time.Duration(num("crewtest.soak_s", 300)) * time.Second)
	workers := num("crewtest.soak_workers", 4)
	s := &soak{
		stallAfter: time.Duration(num("crewtest.soak_stall_s", 30)) * time.Second,
		giveUp:     time.Duration(num("crewtest.soak_give_up_s", 240)) * time.Second,
	}
	cache := &http.Client{Transport: &http.Transport{MaxIdleConnsPerHost: workers, DisableCompression: true}}
	sizes := []int{1 << 20, 8 << 20, 30 << 20, 120 << 20}
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := w; time.Now().Before(until); i++ {
				n := sizes[i%len(sizes)]
				s.get(cache, fmt.Sprintf("http://10.199.0.1/bytes/%d", n), w)
			}
		}(w)
	}
	if url := cmdline["crewtest.dl"]; url != "" {
		every := time.Duration(num("crewtest.dl_every_s", 60)) * time.Second
		tr := &http.Transport{
			// No CA bundle in this guest: a probe, not a trust decision.
			TLSClientConfig:   &tls.Config{InsecureSkipVerify: true},
			DisableKeepAlives: true, DisableCompression: true,
		}
		// With a cache route, 10.199.0.1:53 is the (fake) cache's, so the
		// test resolves the host for us.
		if ip := cmdline["crewtest.dl_ip"]; ip != "" {
			tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
				_, port, _ := net.SplitHostPort(addr)
				return (&net.Dialer{}).DialContext(ctx, network, net.JoinHostPort(ip, port))
			}
		}
		internet := &http.Client{Transport: tr}
		wg.Add(1)
		go func() {
			defer wg.Done()
			for time.Now().Before(until) {
				s.get(internet, url, -1)
				time.Sleep(every)
			}
		}()
	}
	wg.Wait()
	s.mu.Lock()
	r := report{VM: vmID(), UptimeAtInit: uptime(), Soak: &s.r}
	s.mu.Unlock()
	return sendReport(r)
}

type soak struct {
	stallAfter, giveUp time.Duration
	mu                 sync.Mutex
	r                  soakReport
}

type soakReport struct {
	Downloads int         `json:"downloads"`
	Bytes     int64       `json:"bytes"`
	Errors    []string    `json:"errors,omitempty"`
	Stalls    []soakStall `json:"stalls,omitempty"`
}

type soakStall struct {
	URL     string  `json:"url"`
	Worker  int     `json:"worker"`
	Uptime  float64 `json:"uptime_s"`
	Bytes   int64   `json:"bytes"`
	Of      int64   `json:"of"`
	Outcome string  `json:"outcome"`
}

// get downloads url, watching for progress.
func (s *soak) get(c *http.Client, url string, worker int) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var got, size atomic.Int64
	var last atomic.Int64
	last.Store(time.Now().UnixNano())
	var stalledAt atomic.Int64
	done := make(chan struct{})
	go func() {
		t := time.NewTicker(time.Second)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-t.C:
			}
			quiet := time.Since(time.Unix(0, last.Load()))
			if quiet >= s.stallAfter && stalledAt.CompareAndSwap(0, time.Now().UnixNano()) {
				st := soakStall{URL: url, Worker: worker, Uptime: uptime(), Bytes: got.Load(), Of: size.Load()}
				b, _ := json.Marshal(st)
				logf("stall %s", b)
				go exchange("STALL " + string(b))
			}
			if quiet >= s.giveUp {
				cancel()
				return
			}
		}
	}()
	err := func() error {
		req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
		resp, err := c.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			return fmt.Errorf("status %s", resp.Status)
		}
		size.Store(resp.ContentLength)
		buf := make([]byte, 256<<10)
		for {
			k, err := resp.Body.Read(buf)
			if k > 0 {
				got.Add(int64(k))
				last.Store(time.Now().UnixNano())
			}
			if err == io.EOF {
				return nil
			}
			if err != nil {
				return err
			}
		}
	}()
	close(done)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.r.Downloads++
	s.r.Bytes += got.Load()
	if err != nil && len(s.r.Errors) < 50 {
		s.r.Errors = append(s.r.Errors, fmt.Sprintf("worker %d %s: %v", worker, url, err))
	}
	if at := stalledAt.Load(); at != 0 {
		st := soakStall{URL: url, Worker: worker, Bytes: got.Load(), Of: size.Load()}
		since := time.Since(time.Unix(0, at)).Round(time.Second) + s.stallAfter
		switch {
		case err == nil:
			st.Outcome = fmt.Sprintf("resumed; done %v after the last byte", since)
		case ctx.Err() != nil:
			st.Outcome = fmt.Sprintf("still stuck %v after the last byte; gave up", since)
		default:
			st.Outcome = fmt.Sprintf("failed %v after the last byte: %v", since, err)
		}
		s.r.Stalls = append(s.r.Stalls, st)
	}
}
