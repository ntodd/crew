// Crew's admin UI. theme.js loads separately, synchronously in <head>,
// so the theme is set before first paint.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/crew"
import topbar from "../vendor/topbar"
import {LogViewer} from "./log_viewer"
import {formatDuration, HoverController, ServerClock} from "./live_core"

// Keeps a log pinned to its newest line while the reader is at the
// bottom; scrolling up to read stops the pinning until they come back.
const LogTail = {
  mounted() {
    this.pinned = true
    this.el.addEventListener("scroll", () => {
      const gap = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      this.pinned = gap < 24
    })
    this.scroll()
  },
  updated() {
    this.scroll()
  },
  scroll() {
    if (this.pinned) this.el.scrollTop = this.el.scrollHeight
  },
}

// Copies data-copy (or the text of the element named by data-copy-from)
// and flips the button's label for a moment.
const Copy = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const source = this.el.dataset.copyFrom && document.getElementById(this.el.dataset.copyFrom)
      const text = this.el.dataset.copy ?? source?.innerText ?? ""
      try {
        await navigator.clipboard.writeText(text.trim())
        const label = this.el.querySelector("[data-copy-label]")
        if (label) {
          const before = label.textContent
          label.textContent = "Copied"
          setTimeout(() => (label.textContent = before), 1500)
        }
      } catch (_error) {
        // Clipboard access needs a secure context; the text is still selectable.
      }
    })
  },
}

// Sizes flex children from data-grow (and data-min) through the CSSOM:
// production's CSP allows no inline style attributes (§17.1).
const Grow = {
  mounted() {
    this.apply()
  },
  updated() {
    this.apply()
  },
  apply() {
    for (const child of this.el.querySelectorAll("[data-grow]")) {
      child.style.flexGrow = child.dataset.grow
      child.style.flexBasis = "0"
      if (child.dataset.min) child.style.minWidth = child.dataset.min
    }
  },
}

// A card (`data-card`: the id of a manual popover with HoverCardPanel)
// shown while the pointer is on a trigger or the card, or focus is on a
// trigger. The triggers report what happens to them; the card's
// HoverController (live_core.js) decides when it's open and for
// which trigger.
const HoverCard = {
  mounted() {
    const ctl = () => document.getElementById(this.el.dataset.card)?.hoverCard
    this.ctl = ctl
    this.el.addEventListener("pointerenter", () => ctl()?.enter(this.el))
    this.el.addEventListener("pointerleave", () => ctl()?.leave(this.el))
    this.el.addEventListener("focus", () => ctl()?.focus(this.el))
    this.el.addEventListener("blur", () => ctl()?.blur(this.el))
    this.el.addEventListener("keydown", e => e.key === "Escape" && ctl()?.dismiss())
  },
  destroyed() {
    this.ctl()?.remove(this.el)
  },
}

// The card: a manual popover, so it sits in the top layer and a table's
// scroll box doesn't clip it. It goes under its trigger, or over it when
// there's no room below. Its position is set through CSSOM, which the
// strict CSP allows; a server patch drops it, so it's set again after.
// Escape or a scroll closes it, or stops it opening: the listeners are on
// for as long as the card is on the page, and cost nothing when it's shut.
const HoverCardPanel = {
  mounted() {
    this.onKey = e => e.key === "Escape" && this.el.hoverCard.dismiss()
    this.onScroll = () => this.el.hoverCard.dismiss()
    this.el.hoverCard = new HoverController({show: anchor => this.show(anchor), hide: () => this.hide()})
    this.el.addEventListener("pointerenter", () => this.el.hoverCard.enterCard())
    this.el.addEventListener("pointerleave", () => this.el.hoverCard.leaveCard())
    document.addEventListener("keydown", this.onKey)
    window.addEventListener("scroll", this.onScroll, {passive: true, capture: true})
  },
  updated() {
    this.place()
  },
  destroyed() {
    this.el.hoverCard.dismiss()
    document.removeEventListener("keydown", this.onKey)
    window.removeEventListener("scroll", this.onScroll, {capture: true})
  },
  show(anchor) {
    this.anchor = anchor
    if (!this.el.matches(":popover-open")) this.el.showPopover()
    this.place()
  },
  hide() {
    this.anchor = null
    if (this.el.matches(":popover-open")) this.el.hidePopover()
  },
  place() {
    if (!this.anchor?.isConnected || !this.el.matches(":popover-open")) return
    const gap = 6
    const r = this.anchor.getBoundingClientRect()
    const c = this.el.getBoundingClientRect()
    const below = r.bottom + gap + c.height <= window.innerHeight || r.top - gap - c.height < 0
    const top = below ? r.bottom + gap : r.top - gap - c.height
    const left = Math.min(Math.max(8, r.left), window.innerWidth - c.width - 8)
    this.el.style.top = `${Math.round(top)}px`
    this.el.style.left = `${Math.round(left)}px`
  },
}

// Counts up every [data-from] under it once a second, so running times
// move between server renders without the server sending them. It runs
// on the server's clock (`data-now`, the time of the last render).
const Clock = {
  mounted() {
    this.clock = new ServerClock()
    this.clock.sync(this.el.dataset.now)
    this.tick()
    this.timer = setInterval(() => this.tick(), 1000)
  },
  updated() {
    this.clock.sync(this.el.dataset.now)
    this.tick()
  },
  destroyed() {
    clearInterval(this.timer)
  },
  tick() {
    const now = this.clock.now()
    for (const el of this.el.querySelectorAll("[data-from]")) {
      const from = Date.parse(el.dataset.from)
      if (!Number.isNaN(from)) el.textContent = formatDuration((now - from) / 1000)
    }
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, LogTail, Copy, LogViewer, Grow, HoverCard, HoverCardPanel, Clock},
})

topbar.config({barColors: {0: "#5b50e8"}, shadowColor: "rgba(0, 0, 0, .15)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()
  })
}
