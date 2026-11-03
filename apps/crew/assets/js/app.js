// Crew's admin UI. theme.js loads separately, synchronously in <head>,
// so the theme is set before first paint.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/crew"
import topbar from "../vendor/topbar"

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

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, LogTail, Copy},
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
