//go:build linux

package main

// crew mode (the default when the kernel command line has crew.api, as
// the agent's does): a stand-in for crew-guest on a real VM. It walks
// the guest API (§13.4) the way a job VM does, from inside the guest:
// fetch the payload once, say the runner is listening, send a log line
// and a step, then wait for a stop (the guest API's control channel, or
// the power button) and power off. GitHub's side of a job (assignment,
// in_progress, completed) is the test's to drive.

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"syscall"
	"time"
)

func crewMode() error {
	api := strings.TrimRight(cmdline["crew.api"], "/")
	token := cmdline["crew.token"]
	client := &http.Client{Timeout: 10 * time.Second}
	nowMS := func() int64 { return time.Now().UnixMilli() }

	do := func(method, path, ctype string, body []byte, c *http.Client) (int, []byte, error) {
		req, err := http.NewRequest(method, api+path, bytes.NewReader(body))
		if err != nil {
			return 0, nil, err
		}
		req.Header.Set("Authorization", "Bearer "+token)
		if ctype != "" {
			req.Header.Set("Content-Type", ctype)
		}
		resp, err := c.Do(req)
		if err != nil {
			return 0, nil, err
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		return resp.StatusCode, b, nil
	}
	post := func(path string, v any) {
		b, _ := json.Marshal(v)
		if code, _, err := do("POST", path, "application/json", b, client); err != nil || code >= 300 {
			logf("POST %s: %d %v", path, code, err)
		}
	}
	logLine := func(text string) {
		b, _ := json.Marshal(map[string]any{"t": nowMS(), "step_ref": "s1", "text": text})
		do("POST", "/v1/log", "application/x-ndjson", append(b, '\n'), client)
	}

	// The payload, once. The network is up as soon as the kernel is.
	var payload map[string]any
	until := time.Now().Add(60 * time.Second)
	for {
		code, body, err := do("GET", "/v1/payload", "", nil, client)
		if err == nil && code == 200 {
			if err := json.Unmarshal(body, &payload); err != nil {
				return fmt.Errorf("payload: %w", err)
			}
			break
		}
		if code == 410 {
			return fmt.Errorf("payload already fetched")
		}
		if time.Now().After(until) {
			return fmt.Errorf("no payload after 60 s: %d %v", code, err)
		}
		time.Sleep(200 * time.Millisecond)
	}
	jit, _ := payload["jit_config"].(string)
	logf("payload fetched (%d bytes of JIT config)", len(jit))

	stop := make(chan string, 2)
	watchPowerButton(stop)

	post("/v1/state", map[string]any{"state": "runner_listening", "at": nowMS(), "detail": "Listening for Jobs"})
	logLine(fmt.Sprintf("crew-vz test guest on a real VM: kernel up in %.2fs", uptime()))
	post("/v1/steps", map[string]any{"steps": []map[string]any{
		{"ref": "s1", "name": "Boot", "number": 1, "status": "completed", "conclusion": "success", "started_at": nowMS(), "completed_at": nowMS()},
	}})

	// The control channel's long poll: {"stop": true} when the agent stops it.
	go func() {
		long := &http.Client{Timeout: 40 * time.Second}
		for {
			code, body, err := do("GET", "/v1/control", "", nil, long)
			if err == nil && code == 200 && bytes.Contains(body, []byte(`"stop":true`)) {
				stop <- "the guest API asked"
				return
			}
			if err != nil || (code != 200 && code != 204) {
				time.Sleep(time.Second)
			}
		}
	}()

	why := <-stop
	logf("stopping: %s", why)
	logLine("stopping: " + why)
	return nil
}

// watchPowerButton sends on stop when KEY_POWER goes down (VZ's
// requestStop, through gpio-keys).
func watchPowerButton(stop chan<- string) {
	for i := 0; i < 8; i++ {
		fd, err := syscall.Open(fmt.Sprintf("/dev/input/event%d", i), syscall.O_RDONLY, 0)
		if err != nil {
			continue
		}
		go func(fd int) {
			ev := make([]byte, 24) // struct input_event on arm64
			for {
				if n, err := syscall.Read(fd, ev); err != nil || n != 24 {
					return
				}
				typ := binary.LittleEndian.Uint16(ev[16:18])
				code := binary.LittleEndian.Uint16(ev[18:20])
				val := int32(binary.LittleEndian.Uint32(ev[20:24]))
				if typ == 1 && code == 116 && val == 1 {
					stop <- "the power button"
					return
				}
			}
		}(fd)
	}
}
