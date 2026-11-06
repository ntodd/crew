// The run page's pure parts (§17.3), kept apart from the DOM so they can
// be tested on their own: the clock that counts running times up, and
// the hover card's controller.

// Seconds as JobStatus.format writes them: 42s, 3m 04s, 1h 07m.
export function formatDuration(seconds) {
  const s = Math.max(0, Math.floor(seconds))
  const pad = n => String(n).padStart(2, "0")
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m ${pad(s % 60)}s`
  return `${Math.floor(s / 3600)}h ${pad(Math.floor((s % 3600) / 60))}m`
}

// The server's time, carried forward on a monotonic clock, so a browser
// whose clock is off (or moves) counts from the same place the server
// rendered. Only a new server time recalibrates it: a patch that didn't
// re-render the time leaves it running.
export class ServerClock {
  constructor(monotonic = () => performance.now()) {
    this.monotonic = monotonic
    this.last = null
    this.base = null
    this.at = 0
  }

  // A server time behind where the clock has got to arrived late (it was
  // rendered before the moment the clock already shows): it's ignored, so
  // the clock never runs backwards.
  sync(serverTime) {
    if (serverTime === this.last) return
    const base = Date.parse(serverTime)
    const shown = this.base === null ? -Infinity : this.now()
    this.last = serverTime
    this.base = Number.isNaN(base) ? null : Math.max(base, shown)
    this.at = this.monotonic()
  }

  now() {
    return this.base === null ? Date.now() : this.base + (this.monotonic() - this.at)
  }
}

// When one card, shared by any number of triggers, should be open and
// for which. It wants to be open for the focused trigger, else the
// hovered one, else (while the pointer is on the card) the one it's
// open for. Hovering opens after a moment and leaving closes after one,
// so the pointer can cross from a trigger to the card; focus opens at
// once. `show(anchor)` and `hide()` do the DOM side.
export class HoverController {
  constructor({show, hide, setTimeout = globalThis.setTimeout, clearTimeout = globalThis.clearTimeout, openMs = 150, closeMs = 120}) {
    // Called bare: a browser's setTimeout throws on any other `this`.
    this.setTimer = (fn, ms) => setTimeout(fn, ms)
    this.clearTimer = id => clearTimeout(id)
    Object.assign(this, {showFn: show, hideFn: hide, openMs, closeMs})
    this.anchor = null
    this.hovered = null
    this.focused = null
    this.onCard = false
    this.timer = null
  }

  enter(anchor) {
    this.hovered = anchor
    this.later(this.openMs)
  }

  leave(anchor) {
    if (this.hovered === anchor) this.hovered = null
    this.later(this.closeMs)
  }

  focus(anchor) {
    this.focused = anchor
    this.cancel()
    this.settle()
  }

  blur(anchor) {
    if (this.focused === anchor) this.focused = null
    this.later(this.closeMs)
  }

  enterCard() {
    this.onCard = true
    this.cancel()
  }

  leaveCard() {
    this.onCard = false
    this.later(this.closeMs)
  }

  // Escape, a scroll: shut now, and forget who wanted it open.
  dismiss() {
    this.cancel()
    this.hovered = this.focused = null
    this.onCard = false
    this.close()
  }

  // A trigger left the page.
  remove(anchor) {
    if (this.hovered === anchor) this.hovered = null
    if (this.focused === anchor) this.focused = null
    if (this.anchor === anchor) {
      this.cancel()
      this.close()
    }
  }

  later(ms) {
    this.cancel()
    this.timer = this.setTimer(() => {
      this.timer = null
      this.settle()
    }, ms)
  }

  cancel() {
    if (this.timer !== null) this.clearTimer(this.timer)
    this.timer = null
  }

  settle() {
    const want = this.focused ?? this.hovered ?? (this.onCard ? this.anchor : null)
    if (want === null) return this.close()
    if (want !== this.anchor) {
      this.anchor = want
      this.showFn(want)
    }
  }

  close() {
    if (this.anchor === null) return
    this.anchor = null
    this.hideFn()
  }
}

// Where a tip goes for an anchor: over it, centred, `gap` px off, kept
// 8 px inside the window; under it when there's no room over it. Rects
// are viewport ones (getBoundingClientRect), the tip's just its size.
export function placeAbove(anchor, tip, vw, vh, gap = 6) {
  const centre = (anchor.left + anchor.right) / 2
  const left = Math.round(Math.min(Math.max(8, centre - tip.width / 2), vw - tip.width - 8))
  const over = anchor.top - gap - tip.height
  const top = Math.round(over >= 0 ? over : anchor.bottom + gap)
  return {left, top}
}
