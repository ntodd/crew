// The job page's log viewer (§17.6): a hook in a phx-update="ignore"
// container. The server answers range fetches ("lines") and searches
// ("search"), and pushes new lines ("append"), source switches ("source")
// and step updates ("steps"). Only visible lines, plus 200 either side,
// are in the DOM; at most 20,000 lines are held.
import {Rows, parseAnsi, indexAdd, annotationOf, groupTitle, fileLink, groupsToCollapse, firstErrorLine, mergeIndex} from "./log_core.js"

const LINE_H = 20
const OVERSCAN = 200
const MAX_HELD = 20000
const FETCH = 1000
const BLOCK = 1024

const el = (tag, cls, text) => {
  const e = document.createElement(tag)
  if (cls) e.className = cls
  if (text !== undefined) e.textContent = text
  return e
}

export const LogViewer = {
  mounted() {
    const d = this.el.dataset
    this.source = d.source
    this.running = d.running === "true"
    this.failed = d.failed === "true"
    this.repo = d.repo
    this.sha = d.sha
    this.github = d.github || "https://github.com"
    this.index = JSON.parse(d.index || "{}")
    this.index.steps ||= {}
    this.index.groups ||= []
    this.index.annotations ||= []
    this.steps = JSON.parse(d.steps || "[]")
    this.lines = new Map()
    this.inFlight = new Set()
    this.heights = new Map()
    this.blocks = null
    this.rows = new Rows(Number(d.total) || 0)
    this.rows.collapse(groupsToCollapse(this.index, this.steps, this.running))
    this.follow = this.running
    this.fresh = 0
    this.wrap = false
    this.stamps = 0 // 0 off, 1 wall clock, 2 offset from the step's start
    this.hits = []
    this.hit = -1
    this.hitSet = new Set()
    this.selected = null

    this.build()
    this.bind()
    this.handleEvent("append", e => this.onAppend(e))
    this.handleEvent("source", e => this.onSource(e))
    this.handleEvent("steps", e => this.onSteps(e))
    this.handleEvent("index", e => this.onIndex(e))

    const linked = this.readHash()
    if (linked) this.scrollToLine(linked[0], "center")
    else if (this.failed) this.firstError()
    else if (this.follow) this.toBottom()
    this.render()
  },

  destroyed() {
    document.removeEventListener("keydown", this.onKey)
    document.removeEventListener("click", this.onStepClick)
  },

  // -- DOM ---------------------------------------------------------------------

  build() {
    this.el.replaceChildren()
    this.el.classList.add("lv")

    const bar = el("div", "lv-bar")
    this.searchBox = el("input", "lv-search")
    Object.assign(this.searchBox, {type: "search", placeholder: "Search (/)", spellcheck: false})
    this.searchBox.setAttribute("aria-label", "Search the log")
    this.regexBox = this.toggle("Regex", ".*")
    this.caseBox = this.toggle("Match case", "Aa")
    this.counter = el("span", "lv-counter")
    this.counter.setAttribute("aria-live", "polite")
    this.followBtn = this.button("Follow (f)", "Follow", () => this.setFollow(!this.follow))
    this.stampsBtn = this.button("Timestamps (t)", "Time", () => this.cycleStamps())
    this.wrapBtn = this.button("Wrap (w)", "Wrap", () => this.setWrap(!this.wrap))
    this.errorBtn = this.button("First error (e)", "First error", () => this.firstError())
    const help = this.button("Keys (?)", "?", () => this.toggleHelp())
    bar.append(this.searchBox, this.regexBox, this.caseBox, this.counter, el("span", "lv-gap"), this.errorBtn, this.followBtn, this.stampsBtn, this.wrapBtn, help)

    this.annotationsEl = el("div", "lv-annotations")
    this.scroller = el("div", "lv-scroller")
    this.scroller.tabIndex = 0
    this.scroller.setAttribute("role", "log")
    this.scroller.setAttribute("aria-label", "Job log")
    this.spacer = el("div", "lv-spacer")
    this.rowsEl = el("div", "lv-rows")
    this.scroller.append(this.spacer, this.rowsEl)
    this.pill = this.button("Jump to live", "", () => this.setFollow(true))
    this.pill.classList.add("lv-pill")
    this.pill.hidden = true
    this.helpEl = el("div", "lv-help")
    this.helpEl.hidden = true
    for (const [k, v] of [["j / k", "next / previous step"], ["g / G", "top / bottom"], ["f", "follow"], ["t", "timestamps"], ["w", "wrap"], ["e", "first error"], ["/ or Ctrl-F", "search; Enter, Shift-Enter step through"], ["Esc", "close"]]) {
      const row = el("div")
      row.append(el("kbd", "", k), el("span", "", v))
      this.helpEl.append(row)
    }
    this.el.append(bar, this.annotationsEl, this.scroller, this.pill, this.helpEl)
    this.renderAnnotations()
    this.updateButtons()
  },

  button(title, label, onClick) {
    const b = el("button", "lv-btn", label)
    b.type = "button"
    b.title = title
    b.setAttribute("aria-label", title)
    b.addEventListener("click", onClick)
    return b
  },

  toggle(title, label) {
    const b = this.button(title, label, () => {
      b.setAttribute("aria-pressed", b.getAttribute("aria-pressed") === "true" ? "false" : "true")
      if (this.searchBox.value) this.search()
    })
    b.setAttribute("aria-pressed", "false")
    return b
  },

  bind() {
    let ticking = false
    let lastTop = 0
    this.scroller.addEventListener("scroll", () => {
      const top = this.scroller.scrollTop
      const atBottom = top + this.scroller.clientHeight >= this.scroller.scrollHeight - LINE_H * 2
      if (top < lastTop && !atBottom && this.follow) this.setFollow(false)
      if (atBottom && !this.follow && this.running) this.setFollow(true)
      lastTop = top
      if (!ticking) {
        ticking = true
        requestAnimationFrame(() => {
          ticking = false
          this.render()
        })
      }
    })
    new ResizeObserver(() => this.render()).observe(this.scroller)

    this.rowsEl.addEventListener("click", e => {
      const ln = e.target.closest(".lv-ln")
      if (ln) return this.selectLine(Number(ln.dataset.n), e.shiftKey)
      const caret = e.target.closest(".lv-caret")
      if (caret) {
        const start = Number(caret.dataset.n)
        const group = this.index.groups.find(g => g[0] === start)
        if (group) this.rows.toggle(group[0], group[1])
        this.blocks = null
        this.render()
      }
    })

    this.searchBox.addEventListener("keydown", e => {
      if (e.key === "Enter") {
        e.preventDefault()
        if (this.hits.length && this.searchBox.value === this.lastQuery) this.nextHit(e.shiftKey ? -1 : 1)
        else this.search()
      } else if (e.key === "Escape") {
        this.searchBox.blur()
        this.scroller.focus()
      }
    })

    this.onKey = e => this.key(e)
    document.addEventListener("keydown", this.onKey)

    // The page's steps list scrolls the log to its step.
    this.onStepClick = e => {
      const b = e.target.closest("#steps [data-step-number]")
      if (!b) return
      const step = this.steps.find(s => String(s.number) === b.dataset.stepNumber)
      if (step?.ref && step.ref in this.index.steps) this.scrollToLine(this.index.steps[step.ref], "start")
    }
    document.addEventListener("click", this.onStepClick)
  },

  // -- geometry -----------------------------------------------------------------

  height(n) {
    return this.wrap ? this.heights.get(n) || LINE_H : LINE_H
  },

  // Sums of BLOCK rows, so offsets in wrap mode don't walk every row.
  blockSums() {
    if (this.blocks) return this.blocks
    const count = this.rows.count()
    const sums = []
    for (let start = 1; start <= count; start += BLOCK) {
      let sum = 0
      const end = Math.min(count, start + BLOCK - 1)
      for (let r = start; r <= end; r++) sum += this.height(this.rows.lineAt(r))
      sums.push(sum)
    }
    this.blocks = sums
    return sums
  },

  rowTop(row) {
    if (!this.wrap) return (row - 1) * LINE_H
    const sums = this.blockSums()
    const b = Math.floor((row - 1) / BLOCK)
    let top = 0
    for (let i = 0; i < b; i++) top += sums[i]
    for (let r = b * BLOCK + 1; r < row; r++) top += this.height(this.rows.lineAt(r))
    return top
  },

  rowAt(y) {
    const count = this.rows.count()
    if (!this.wrap) return Math.min(count, Math.max(1, Math.floor(y / LINE_H) + 1))
    const sums = this.blockSums()
    let top = 0
    let b = 0
    while (b < sums.length && top + sums[b] <= y) top += sums[b++]
    let r = b * BLOCK + 1
    while (r < count && top + this.height(this.rows.lineAt(r)) <= y) top += this.height(this.rows.lineAt(r++))
    return Math.min(count, Math.max(1, r))
  },

  totalHeight() {
    return this.wrap ? this.blockSums().reduce((a, b) => a + b, 0) : this.rows.count() * LINE_H
  },

  // -- rendering ----------------------------------------------------------------

  render() {
    const count = this.rows.count()
    this.spacer.style.height = `${this.totalHeight()}px`
    if (!count) {
      this.rowsEl.replaceChildren(el("div", "lv-empty", this.running ? "Waiting for the first lines…" : "No log lines."))
      return
    }
    const top = this.scroller.scrollTop
    const first = Math.max(1, this.rowAt(top) - OVERSCAN)
    const last = Math.min(count, this.rowAt(top + this.scroller.clientHeight) + OVERSCAN)
    this.window = [first, last]

    const missing = []
    const frag = document.createDocumentFragment()
    let y = this.rowTop(first)
    let measured = false
    const rendered = []
    for (let r = first; r <= last; r++) {
      const n = this.rows.lineAt(r)
      const line = this.lines.get(n)
      if (!line) missing.push(n)
      const row = this.lineEl(n, line)
      row.style.transform = `translateY(${y}px)`
      frag.append(row)
      rendered.push([n, row])
      y += this.height(n)
    }
    this.rowsEl.replaceChildren(frag)

    if (this.wrap) {
      for (const [n, row] of rendered) {
        const h = row.offsetHeight
        if (h && h !== this.heights.get(n)) {
          this.heights.set(n, h)
          measured = true
        }
      }
      if (measured) {
        this.blocks = null
        requestAnimationFrame(() => this.render())
      }
    }
    if (missing.length) this.fetch(missing)
    if (this.follow) this.scroller.scrollTop = this.scroller.scrollHeight
  },

  lineEl(n, line) {
    const row = el("div", "lv-line")
    row.dataset.n = n
    if (this.hitSet.has(n)) row.classList.add(this.hits[this.hit] === n ? "lv-hit-current" : "lv-hit")
    if (this.selected && n >= this.selected[0] && n <= this.selected[1]) row.classList.add("lv-selected")

    const ln = el("span", "lv-ln", String(n))
    ln.dataset.n = n
    ln.setAttribute("role", "link")
    ln.title = `Link to line ${n}`
    row.append(ln)

    if (!line) {
      row.append(el("span", "lv-tx lv-loading", "…"))
      return row
    }
    if (this.stamps) row.append(el("span", "lv-ts", this.stamp(line)))

    const group = this.index.groups.find(g => g[0] === n)
    if (group) {
      const caret = el("span", "lv-caret", this.rows.isCollapsed(n) ? "▸" : "▾")
      caret.dataset.n = n
      caret.setAttribute("role", "button")
      caret.title = this.rows.isCollapsed(n) ? "Expand" : "Collapse"
      row.append(caret)
      row.classList.add("lv-group")
    }

    const tx = el("span", "lv-tx")
    const annotation = annotationOf(line.text)
    const title = group ? groupTitle(line.text) : null
    if (annotation) {
      row.classList.add(`lv-${annotation.level}`)
      tx.append(el("span", `lv-badge lv-badge-${annotation.level}`, annotation.level))
      const link = annotation.file && fileLink(this.github, this.repo, this.sha, annotation.file, annotation.line)
      if (link) {
        const a = el("a", "lv-file", `${annotation.file}${annotation.line ? `:${annotation.line}` : ""}`)
        a.href = link
        a.target = "_blank"
        a.rel = "noopener noreferrer"
        tx.append(a, document.createTextNode(" "))
      }
      tx.append(document.createTextNode(annotation.text))
    } else if (title !== null) {
      tx.append(el("span", "lv-group-title", title))
    } else {
      for (const run of parseAnsi(line.text)) {
        if (run.cls) tx.append(el("span", run.cls, run.text))
        else tx.append(document.createTextNode(run.text))
      }
    }
    row.append(tx)
    return row
  },

  stamp(line) {
    if (!line.t) return ""
    if (this.stamps === 1) return new Date(line.t).toISOString().slice(11, 23)
    const step = this.steps.find(s => s.ref === line.step_ref)
    const start = step?.started_at ? Date.parse(step.started_at) : null
    if (!start) return ""
    const s = Math.max(0, (line.t - start) / 1000)
    return `+${s < 60 ? s.toFixed(1) + "s" : Math.floor(s / 60) + "m" + String(Math.floor(s % 60)).padStart(2, "0") + "s"}`
  },

  renderAnnotations() {
    const list = this.index.annotations
    this.annotationsEl.replaceChildren()
    this.annotationsEl.hidden = !list.length
    if (!list.length) return
    const counts = {}
    for (const a of list) counts[a.level] = (counts[a.level] || 0) + 1
    const summary = el("span", "lv-ann-summary", Object.entries(counts).map(([k, v]) => `${v} ${k}${v === 1 ? "" : "s"}`).join(" · "))
    this.annotationsEl.append(summary)
    for (const a of list.slice(0, 20)) {
      const b = this.button(`Line ${a.n}`, "", () => this.scrollToLine(a.n, "center"))
      b.classList.add("lv-ann", `lv-badge-${a.level}`)
      b.append(el("span", "lv-ann-level", a.level), document.createTextNode(` ${a.text.slice(0, 80)}`))
      this.annotationsEl.append(b)
    }
    if (list.length > 20) this.annotationsEl.append(el("span", "lv-ann-more", `+${list.length - 20} more`))
  },

  updateButtons() {
    this.followBtn.setAttribute("aria-pressed", String(this.follow))
    this.wrapBtn.setAttribute("aria-pressed", String(this.wrap))
    this.stampsBtn.setAttribute("aria-pressed", String(this.stamps > 0))
    this.stampsBtn.textContent = ["Time", "Clock", "Offset"][this.stamps]
    this.errorBtn.hidden = !this.failed
    this.followBtn.hidden = !this.running
    this.el.classList.toggle("lv-wrap", this.wrap)
    this.pill.hidden = this.follow || this.fresh === 0
    this.pill.textContent = `Jump to live (${this.fresh} new)`
  },

  // -- data ---------------------------------------------------------------------

  fetch(missing) {
    // Contiguous runs, up to FETCH lines each, not already asked for.
    const runs = []
    for (const n of missing) {
      if (this.inFlight.has(n)) continue
      const last = runs[runs.length - 1]
      if (last && n === last[1] + 1 && n - last[0] < FETCH) last[1] = n
      else runs.push([n, n])
    }
    const source = this.source
    for (const [from, to] of runs) {
      for (let n = from; n <= to; n++) this.inFlight.add(n)
      this.pushEvent("lines", {source, from, to}, reply => {
        for (let n = from; n <= to; n++) this.inFlight.delete(n)
        if (source !== this.source || !reply.lines) return
        for (const line of reply.lines) this.lines.set(line.n, line)
        this.evict()
        this.render()
      })
    }
  },

  // At most MAX_HELD lines: the farthest from what's on screen go.
  evict() {
    if (this.lines.size <= MAX_HELD) return
    const [a, b] = this.window || [1, 1]
    const centre = this.rows.lineAt(Math.floor((a + b) / 2))
    const far = [...this.lines.keys()].sort((x, y) => Math.abs(y - centre) - Math.abs(x - centre))
    for (const n of far.slice(0, this.lines.size - MAX_HELD)) this.lines.delete(n)
  },

  onAppend({source, lines, total}) {
    if (source !== this.source) return
    const before = this.rows.total
    for (const line of lines) this.lines.set(line.n, line)
    indexAdd(this.index, lines)
    this.rows.setTotal(Math.max(total, before))
    this.blocks = null
    if (lines.some(l => annotationOf(l.text))) this.renderAnnotations()
    if (!this.follow) this.fresh += Math.max(0, total - before)
    this.evict()
    this.updateButtons()
    this.render()
  },

  // GitHub's log arrived: switch, keeping the place by step and line.
  onSource({source, total, index, steps}) {
    const top = this.rows.lineAt(this.rowAt(this.scroller.scrollTop))
    const line = this.lines.get(top)
    const oldStep = line && this.steps.find(s => s.ref === line.step_ref)
    const offset = oldStep ? top - (this.index.steps[oldStep.ref] || top) : 0

    this.source = source
    this.index = index
    this.steps = steps
    this.lines = new Map()
    this.inFlight = new Set()
    this.heights = new Map()
    this.blocks = null
    this.rows = new Rows(total)
    this.rows.collapse(groupsToCollapse(index, steps, false))
    this.running = false
    this.follow = false
    this.renderAnnotations()
    this.updateButtons()

    const newStep = oldStep && steps.find(s => s.number === oldStep.number)
    const start = newStep?.ref && index.steps[newStep.ref]
    this.render()
    if (start) this.scrollToLine(start + offset, "start")
  },

  onIndex({index}) {
    const {index: merged, added} = mergeIndex(this.index, index)
    this.index = merged
    // Groups it didn't know start folded as they would have at load.
    const fold = groupsToCollapse({...merged, groups: added}, this.steps, this.running)
    if (fold.length) this.rows.collapse(fold)
    this.blocks = null
    this.renderAnnotations()
    this.render()
  },

  onSteps({steps, running}) {
    this.steps = steps
    this.running = running
    if (!running) this.follow = false
    this.updateButtons()
  },

  // -- moving around ----------------------------------------------------------------

  scrollToLine(n, where = "start") {
    const row = this.rows.rowOf(Math.max(1, Math.min(n, this.rows.total)))
    const top = this.rowTop(row)
    const offset = where === "center" ? this.scroller.clientHeight / 2 - LINE_H : 0
    this.setFollow(false)
    this.scroller.scrollTop = Math.max(0, top - offset)
    this.render()
  },

  toBottom() {
    this.scroller.scrollTop = this.scroller.scrollHeight
  },

  setFollow(on) {
    this.follow = on && this.running
    if (this.follow) {
      this.fresh = 0
      this.toBottom()
    }
    this.updateButtons()
  },

  setWrap(on) {
    this.wrap = on
    this.blocks = null
    this.heights = new Map()
    this.updateButtons()
    this.render()
  },

  cycleStamps() {
    this.stamps = (this.stamps + 1) % 3
    this.updateButtons()
    this.render()
  },

  firstError() {
    const n = firstErrorLine(this.index, this.steps, this.rows.total)
    if (n) this.scrollToLine(n, "center")
  },

  stepStarts() {
    return Object.values(this.index.steps).sort((a, b) => a - b)
  },

  jumpStep(dir) {
    const current = this.rows.lineAt(this.rowAt(this.scroller.scrollTop + 1))
    const starts = this.stepStarts()
    const next = dir > 0 ? starts.find(s => s > current) : [...starts].reverse().find(s => s < current)
    if (next) this.scrollToLine(next, "start")
  },

  // -- line links (#L123, #L120-L140) ---------------------------------------------

  readHash() {
    const m = location.hash.match(/^#L(\d+)(?:-L(\d+))?$/)
    if (!m) return null
    const a = Number(m[1])
    const b = m[2] ? Number(m[2]) : a
    this.selected = [Math.min(a, b), Math.max(a, b)]
    return this.selected
  },

  selectLine(n, extend) {
    if (extend && this.selected) this.selected = [Math.min(this.selected[0], n), Math.max(this.selected[1], n)]
    else this.selected = [n, n]
    const [a, b] = this.selected
    history.replaceState(null, "", a === b ? `#L${a}` : `#L${a}-L${b}`)
    this.render()
  },

  // -- search --------------------------------------------------------------------

  search() {
    const q = this.searchBox.value
    this.lastQuery = q
    if (!q) {
      this.hits = []
      this.hitSet = new Set()
      this.counter.textContent = ""
      return this.render()
    }
    this.counter.textContent = "Searching…"
    const params = {source: this.source, q, regex: this.regexBox.getAttribute("aria-pressed") === "true", case: this.caseBox.getAttribute("aria-pressed") === "true"}
    this.pushEvent("search", params, reply => {
      if (reply.error) {
        this.hits = []
        this.hitSet = new Set()
        this.counter.textContent = reply.error
        return this.render()
      }
      this.hits = reply.hits
      this.hitSet = new Set(reply.hits)
      this.hit = -1
      if (this.hits.length) this.nextHit(1)
      else {
        this.counter.textContent = "No matches"
        this.render()
      }
    })
  },

  nextHit(dir) {
    if (!this.hits.length) return
    this.hit = (this.hit + dir + this.hits.length) % this.hits.length
    const n = this.hits[this.hit]
    this.counter.textContent = `${this.hit + 1} / ${this.hits.length}${this.hits.length >= 10000 ? "+" : ""}`
    // A hit inside a collapsed group opens it.
    const group = this.index.groups.find(([s, e]) => n > s && (e === null || n <= e) && this.rows.isCollapsed(s))
    if (group) {
      this.rows.expand(group[0])
      this.blocks = null
    }
    this.scrollToLine(n, "center")
  },

  toggleHelp() {
    this.helpEl.hidden = !this.helpEl.hidden
  },

  // -- keys ------------------------------------------------------------------------

  key(e) {
    const typing = e.target.closest?.("input, textarea, select, [contenteditable]")
    if ((e.key === "/" && !typing) || ((e.ctrlKey || e.metaKey) && e.key === "f")) {
      e.preventDefault()
      this.searchBox.focus()
      this.searchBox.select()
      return
    }
    if (typing || e.ctrlKey || e.metaKey || e.altKey) return
    const actions = {
      j: () => this.jumpStep(1),
      k: () => this.jumpStep(-1),
      g: () => this.scrollToLine(1, "start"),
      G: () => {
        this.scroller.scrollTop = this.scroller.scrollHeight
        this.render()
      },
      f: () => this.setFollow(!this.follow),
      t: () => this.cycleStamps(),
      w: () => this.setWrap(!this.wrap),
      e: () => this.firstError(),
      "?": () => this.toggleHelp(),
      Escape: () => {
        this.helpEl.hidden = true
      },
    }
    const action = actions[e.key]
    if (action) {
      e.preventDefault()
      action()
    }
  },
}
