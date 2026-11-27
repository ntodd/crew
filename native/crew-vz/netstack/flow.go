package netstack

import (
	"net"
	"net/netip"
	"sort"
	"sync/atomic"
	"time"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
)

// A flow is one proxied TCP connection, tracked while it's open so the
// watchdog can find stalls, and so whatever is still open when the VM goes
// gets logged.
//
// A stall is a guest that owes an answer and sends nothing at all on the
// flow for the stall timeout. It owes one once gVisor's retransmission
// timer fires after the guest's last segment: the timer runs only while
// bytes to the guest are unacknowledged or its window is closed. A live
// guest always answers: it acknowledges data, and when it isn't reading
// it still answers the window probes gVisor sends every guestMaxRTO at
// most. So a guest applying backpressure is never a stall, and neither is
// an idle flow, which arms no timer. The remote side
// is the macOS kernel's: its retransmission timeout and keepalive end a
// dead peer, and a live one that stops reading is backpressure too.
//
// The reset aborts the guest's endpoint while it's still connected, so the
// guest is sent a RST. gVisor's own give-up (retransmissions past
// TCPMaxRetriesOption) sends nothing, so tuneTCP keeps it well past the
// stall timeout.
type flow struct {
	dst     netip.AddrPort
	started time.Time
	ep      tcpip.Endpoint // the guest's end
	guest   *gonet.TCPConn
	remote  net.Conn

	toGuest, toRemote flowDir
	stalled           atomic.Bool

	// The watchdog's alone.
	seen     bool
	segsIn   uint64    // the guest's segments when it was last heard from
	rto      uint64    // gVisor's retransmission timeouts then
	owedFrom time.Time // the guest has owed an answer since; zero if it doesn't
	owedSnap tcpSnap   // the counters then
}

// flowDir is one direction of a flow.
type flowDir struct {
	bytes      atomic.Int64 // taken by the receiver
	lastRead   atomic.Int64 // unix ns of the last byte from the sender; 0 for none yet
	writeSince atomic.Int64 // unix ns the pending write began; 0 for none
}

func (n *Netstack) track(f *flow) *flow {
	n.fmu.Lock()
	n.flows[f] = struct{}{}
	n.fmu.Unlock()
	return f
}

func (n *Netstack) untrack(f *flow) {
	n.fmu.Lock()
	delete(n.flows, f)
	n.fmu.Unlock()
}

func (n *Netstack) openFlows() []*flow {
	n.fmu.Lock()
	defer n.fmu.Unlock()
	open := make([]*flow, 0, len(n.flows))
	for f := range n.flows {
		open = append(open, f)
	}
	return open
}

// flowReader reads one side of a flow, noting when bytes arrive.
type flowReader struct {
	conn net.Conn
	dir  *flowDir
}

func (r *flowReader) Read(p []byte) (int, error) {
	k, err := r.conn.Read(p)
	if k > 0 {
		r.dir.lastRead.Store(time.Now().UnixNano())
	}
	return k, err
}

// flowWriter writes one side of a flow, noting what was taken and how long
// the pending write has waited.
type flowWriter struct {
	conn net.Conn
	dir  *flowDir
}

func (w *flowWriter) Write(p []byte) (int, error) {
	w.dir.writeSince.Store(time.Now().UnixNano())
	defer w.dir.writeSince.Store(0)
	k, err := w.conn.Write(p)
	w.dir.bytes.Add(int64(k))
	return k, err
}

// watch checks every flow a few times per stall timeout until Close.
func (n *Netstack) watch() {
	t := time.NewTicker(max(n.stall/8, 10*time.Millisecond))
	defer t.Stop()
	for {
		select {
		case <-n.ctx.Done():
			return
		case <-t.C:
		}
		now := time.Now()
		for _, f := range n.openFlows() {
			n.check(f, now)
		}
	}
}

// check resets f if the guest has owed an answer on it, and said nothing,
// for the stall timeout.
func (n *Netstack) check(f *flow, now time.Time) {
	s := n.snap(f.ep)
	switch {
	case !f.seen || s.segsIn != f.segsIn: // heard from: it owes nothing
		f.seen, f.segsIn, f.rto, f.owedFrom = true, s.segsIn, s.rtoTimeouts, time.Time{}
		return
	case f.owedFrom.IsZero():
		if s.rtoTimeouts != f.rto {
			f.owedFrom, f.owedSnap = now, s
		}
		return
	case now.Sub(f.owedFrom) < n.stall || !f.stalled.CompareAndSwap(false, true):
		return
	}
	n.stalledFlows.Add(1)
	then := f.owedSnap
	attrs := append(f.attrs(now), "why", "guest silent while owing an answer", "stall_s", n.stall.Seconds())
	attrs = append(attrs, tcpAttrs(f.ep)...)
	attrs = append(attrs,
		"during_stall_s", s.at.Sub(then.at).Seconds(),
		"segs_out_during_stall", s.segsOut-then.segsOut,
		"retransmits_during_stall", s.retransmits-then.retransmits,
		"rto_timeouts_during_stall", s.rtoTimeouts-then.rtoTimeouts,
		"link_frames_in_during_stall", s.framesIn-then.framesIn,
		"link_frames_out_during_stall", s.framesOut-then.framesOut,
		"link_frames_lost_during_stall", s.framesLost-then.framesLost,
	)
	n.log.Warn("tcp flow stalled; resetting it", attrs...)
	abort(f.guest, f.remote, f.ep)
}

// tcpSnap is the guest endpoint's counters, and the link's, at one time.
type tcpSnap struct {
	at                                        time.Time
	segsIn, segsOut, retransmits, rtoTimeouts uint64
	framesIn, framesOut, framesLost           uint64
}

func (n *Netstack) snap(ep tcpip.Endpoint) tcpSnap {
	s := tcpSnap{
		at:         time.Now(),
		framesIn:   n.link.framesIn.Load(),
		framesOut:  n.link.framesOut.Load(),
		framesLost: n.link.framesLost.Load(),
	}
	if st, ok := ep.Stats().(*tcp.Stats); ok {
		s.segsIn = st.SegmentsReceived.Value()
		s.segsOut = st.SegmentsSent.Value()
		s.retransmits = st.SendErrors.Retransmits.Value()
		s.rtoTimeouts = st.SendErrors.Timeouts.Value()
	}
	return s
}

// attrs describes the flow for a log line.
func (f *flow) attrs(now time.Time) []any {
	a := []any{
		"dst", f.dst.String(),
		"age_s", now.Sub(f.started).Seconds(),
		"bytes_to_guest", f.toGuest.bytes.Load(),
		"bytes_to_remote", f.toRemote.bytes.Load(),
		"idle_from_remote_s", f.idle(&f.toGuest, now).Seconds(),
		"idle_from_guest_s", f.idle(&f.toRemote, now).Seconds(),
	}
	for _, d := range []struct {
		name string
		dir  *flowDir
	}{{"guest", &f.toGuest}, {"remote", &f.toRemote}} {
		if since := d.dir.writeSince.Load(); since != 0 {
			a = append(a, "write_pending_to_"+d.name+"_s", now.Sub(time.Unix(0, since)).Seconds())
		}
	}
	return a
}

// idle is how long since the sender of d last sent a byte (or since the
// flow began, if it never has).
func (f *flow) idle(d *flowDir, now time.Time) time.Duration {
	if last := d.lastRead.Load(); last != 0 {
		return now.Sub(time.Unix(0, last))
	}
	return now.Sub(f.started)
}

func tcpAttrs(ep tcpip.Endpoint) []any {
	var a []any
	var info tcpip.TCPInfoOption
	if err := ep.GetSockOpt(&info); err == nil {
		a = append(a,
			"guest_tcp_state", tcp.EndpointState(info.State).String(),
			"cc_state", ccStateName(info.CcState),
			"rtt_ms", info.RTT.Milliseconds(),
			"rto_ms", info.RTO.Milliseconds(),
			"cwnd", info.SndCwnd,
		)
	}
	if q, err := ep.GetSockOptInt(tcpip.ReceiveQueueSizeOption); err == nil {
		a = append(a, "recv_queue_bytes", q)
	}
	return a
}

func ccStateName(s tcpip.CongestionControlState) string {
	switch s {
	case tcpip.Open:
		return "open"
	case tcpip.RTORecovery:
		return "rto_recovery"
	case tcpip.FastRecovery:
		return "fast_recovery"
	case tcpip.SACKRecovery:
		return "sack_recovery"
	case tcpip.Disorder:
		return "disorder"
	}
	return "unknown"
}

// logOpenFlows logs the flows still open, longest idle first: when a job
// hung, the flow it was waiting on is here, with how far it got.
func (n *Netstack) logOpenFlows() {
	open := n.openFlows()
	now := time.Now()
	quiet := func(f *flow) time.Duration { return min(f.idle(&f.toGuest, now), f.idle(&f.toRemote, now)) }
	sort.Slice(open, func(i, j int) bool { return quiet(open[i]) > quiet(open[j]) })
	for i, f := range open {
		if i == maxClosingFlowLogs {
			n.log.Info("more tcp flows open at close", "not_logged", len(open)-i)
			break
		}
		n.log.Info("tcp flow open at close", append(f.attrs(now), tcpAttrs(f.ep)...)...)
	}
}
