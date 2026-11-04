// The log viewer's pure parts (§17.6), tested with node --test (js/test).

// -- ANSI ---------------------------------------------------------------------

// xterm's 16 colours, for mapping 256-colour and 24-bit to the nearest class.
const PALETTE = [
  [0, 0, 0], [205, 0, 0], [0, 205, 0], [205, 205, 0], [0, 0, 238], [205, 0, 205], [0, 205, 205], [229, 229, 229],
  [127, 127, 127], [255, 0, 0], [0, 255, 0], [255, 255, 0], [92, 92, 255], [255, 0, 255], [0, 255, 255], [255, 255, 255],
]

export function nearest16(r, g, b) {
  let best = 0
  let bestD = Infinity
  PALETTE.forEach(([pr, pg, pb], i) => {
    const d = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2
    if (d < bestD) [best, bestD] = [i, d]
  })
  return best
}

function rgb256(n) {
  if (n < 16) return PALETTE[n]
  if (n >= 232) {
    const v = 8 + (n - 232) * 10
    return [v, v, v]
  }
  const i = n - 16
  const c = x => (x === 0 ? 0 : 55 + x * 40)
  return [c(Math.floor(i / 36)), c(Math.floor(i / 6) % 6), c(i % 6)]
}

const color = n => (n < 16 ? n : nearest16(...rgb256(n)))

// CSI (ESC [ ... final), OSC (ESC ] ... BEL or ST), two-byte escapes,
// and a lone ESC.
const ESCAPE = /\u001b(?:\[([0-?]*)[ -/]*([@-~])|\][^\u0007\u001b]*(?:\u0007|\u001b\\)|[@-Z\\-_]|)/g

// Text into runs of {text, cls}. Only SGR changes the style; every other
// escape is dropped. The caller puts each run in as a text node.
export function parseAnsi(input) {
  const runs = []
  let style = {fg: null, bg: null, b: false, dim: false, i: false, u: false}
  let last = 0
  const push = text => {
    if (!text) return
    const cls = classOf(style)
    const prev = runs[runs.length - 1]
    if (prev && prev.cls === cls) prev.text += text
    else runs.push({text, cls})
  }
  for (const m of input.matchAll(ESCAPE)) {
    push(input.slice(last, m.index))
    last = m.index + m[0].length
    if (m[2] === "m") style = sgr(style, m[1])
  }
  push(input.slice(last))
  return runs.length ? runs : [{text: "", cls: ""}]
}

function classOf(s) {
  return [s.fg !== null && `fg-${s.fg}`, s.bg !== null && `bg-${s.bg}`, s.b && "b", s.dim && "dim", s.i && "i", s.u && "u"]
    .filter(Boolean)
    .join(" ")
}

function sgr(style, params) {
  const s = {...style}
  const codes = params === "" ? [0] : params.split(";").map(x => (x === "" ? 0 : Number(x)))
  for (let k = 0; k < codes.length; k++) {
    const c = codes[k]
    if (c === 0) Object.assign(s, {fg: null, bg: null, b: false, dim: false, i: false, u: false})
    else if (c === 1) s.b = true
    else if (c === 2) s.dim = true
    else if (c === 3) s.i = true
    else if (c === 4) s.u = true
    else if (c === 22) [s.b, s.dim] = [false, false]
    else if (c === 23) s.i = false
    else if (c === 24) s.u = false
    else if (c >= 30 && c <= 37) s.fg = c - 30
    else if (c >= 90 && c <= 97) s.fg = c - 90 + 8
    else if (c === 39) s.fg = null
    else if (c >= 40 && c <= 47) s.bg = c - 40
    else if (c >= 100 && c <= 107) s.bg = c - 100 + 8
    else if (c === 49) s.bg = null
    else if ((c === 38 || c === 48) && codes[k + 1] === 5) {
      const n = codes[k + 2] ?? 0
      if (c === 38) s.fg = color(n)
      else s.bg = color(n)
      k += 2
    } else if ((c === 38 || c === 48) && codes[k + 1] === 2) {
      const n = nearest16(codes[k + 2] ?? 0, codes[k + 3] ?? 0, codes[k + 4] ?? 0)
      if (c === 38) s.fg = n
      else s.bg = n
      k += 4
    }
  }
  return s
}

export const stripAnsi = text => text.replace(ESCAPE, "")

// -- rows: lines with collapsed groups hidden ------------------------------------

// A group [start, end] collapsed hides start+1..end; its header stays.
export class Rows {
  constructor(total) {
    this.total = total
    this.hidden = new Map() // start -> end (null: to the end of the log)
    this.ranges = []
  }

  setTotal(total) {
    this.total = total
    this.rebuild()
  }

  collapse(groups) {
    for (const [start, end] of groups) this.hidden.set(start, end)
    this.rebuild()
  }

  expand(start) {
    this.hidden.delete(start)
    this.rebuild()
  }

  toggle(start, end) {
    if (this.hidden.has(start)) this.expand(start)
    else this.collapse([[start, end]])
  }

  isCollapsed(start) {
    return this.hidden.has(start)
  }

  // A folded group that was still open takes its end once the index has it.
  syncEnds(groups) {
    let changed = false
    for (const [start, end] of groups) {
      if (end !== null && this.hidden.has(start) && this.hidden.get(start) === null) {
        this.hidden.set(start, end)
        changed = true
      }
    }
    if (changed) this.rebuild()
  }

  // Opens every fold that hides line n, so a jump to it lands on it.
  reveal(n) {
    let changed = false
    for (const [start, end] of [...this.hidden]) {
      if (n > start && n <= (end ?? this.total)) {
        this.hidden.delete(start)
        changed = true
      }
    }
    if (changed) this.rebuild()
    return changed
  }

  // Sorted, merged [from, to] hidden line ranges with cumulative counts.
  rebuild() {
    const raw = [...this.hidden]
      .map(([s, e]) => [s + 1, Math.min(e ?? this.total, this.total)])
      .filter(([a, b]) => a <= b)
      .sort((x, y) => x[0] - y[0])
    const merged = []
    for (const [a, b] of raw) {
      const prev = merged[merged.length - 1]
      if (prev && a <= prev[1] + 1) prev[1] = Math.max(prev[1], b)
      else merged.push([a, b])
    }
    let before = 0
    this.ranges = merged.map(([a, b]) => {
      const r = {from: a, to: b, before}
      before += b - a + 1
      return r
    })
    this.hiddenCount = before
  }

  count() {
    return this.total - (this.hiddenCount || 0)
  }

  // Row (1-based) to line number.
  lineAt(row) {
    let n = row
    for (const r of this.ranges) {
      if (n >= r.from) n += r.to - r.from + 1
      else break
    }
    return n
  }

  // Line number to row; a hidden line maps to its group's header row.
  rowOf(n) {
    let hiddenBefore = 0
    for (const r of this.ranges) {
      if (n > r.to) hiddenBefore += r.to - r.from + 1
      else if (n >= r.from) return r.from - 1 - hiddenBefore
      else break
    }
    return n - hiddenBefore
  }
}

// -- the index, mirrored for lines that arrive live (Crew.Logs.Index) -------------

const GROUP = /^(?:::group::|##\[group\])(.*)$/s
const ENDGROUP = /^(?:::endgroup::|##\[endgroup\])/
const ANNOTATION = /^(?:::(error|warning|notice)(?:\s+([^:]*))?::|##\[(error|warning|notice)\])(.*)$/s
const MAX_ANNOTATIONS = 1000

export function annotationOf(text) {
  const m = stripAnsi(text).match(ANNOTATION)
  if (!m) return null
  const props = Object.fromEntries(
    (m[2] || "")
      .split(",")
      .map(kv => kv.split("=").map(x => x.trim()))
      .filter(kv => kv.length === 2 && kv[0]),
  )
  const line = props.line ? parseInt(props.line, 10) : null
  return {level: m[1] || m[3], text: m[4].trim(), file: props.file || null, line: Number.isFinite(line) ? line : null}
}

export function groupTitle(text) {
  const m = stripAnsi(text).match(GROUP)
  return m ? m[1].trim() : null
}

export const isEndGroup = text => ENDGROUP.test(stripAnsi(text))

export function indexAdd(index, lines) {
  for (const line of lines) {
    if (line.step_ref && !(line.step_ref in index.steps)) index.steps[line.step_ref] = line.n
    const title = groupTitle(line.text)
    const open = index.groups.length && index.groups[index.groups.length - 1][1] === null
    if (title !== null) {
      if (open) index.groups[index.groups.length - 1][1] = line.n - 1
      index.groups.push([line.n, null, title])
    } else if (isEndGroup(line.text)) {
      if (open) index.groups[index.groups.length - 1][1] = line.n
    } else if (index.annotations.length < MAX_ANNOTATIONS) {
      const a = annotationOf(line.text)
      if (a) index.annotations.push({n: line.n, ...a})
    }
  }
  return index
}

// -- links -----------------------------------------------------------------------

// Only https://github.com/<repo>/blob/<sha>/<path>#L<line> (§17.6). Dot
// segments go, and each segment is encoded.
export function fileLink(github, repo, sha, path, line) {
  if (!sha || !repo || !path) return null
  const segments = path.split("/").filter(s => s && s !== "." && s !== "..").map(encodeURIComponent)
  if (!segments.length) return null
  return `${github}/${repo}/blob/${encodeURIComponent(sha)}/${segments.join("/")}${line ? `#L${line}` : ""}`
}

// -- which groups start collapsed, and where the first error is --------------------

function stepOfLine(index, n) {
  let best = null
  for (const [ref, start] of Object.entries(index.steps)) {
    if (start <= n && (!best || start > best[1])) best = [ref, start]
  }
  return best && best[0]
}

// Groups start collapsed in finished steps, and open in the running one
// (§17.6). While the job runs, a group whose step isn't known to be
// finished stays open; an open group (no end yet) always does.
export function groupsToCollapse(index, steps, running) {
  const finished = new Set(steps.filter(s => s.status === "completed").map(s => s.ref))
  return index.groups
    .filter(([start, end]) => end !== null && (!running || finished.has(stepOfLine(index, start))))
    .map(([start, end]) => [start, end])
}

// The first ::error; otherwise the last 50 lines of the failed step.
export function firstErrorLine(index, steps, total) {
  const error = index.annotations.find(a => a.level === "error")
  if (error) return error.n
  const failed = steps.find(s => s.conclusion === "failure" && s.ref && s.ref in index.steps)
  if (!failed) return null
  const start = index.steps[failed.ref]
  const after = Object.values(index.steps).filter(n => n > start)
  const end = after.length ? Math.min(...after) - 1 : total
  return Math.max(start, end - 49)
}

// The server's index (saved by the log's stream about once a second)
// merged into what the viewer learned from live lines. Returns the
// merged index and the groups it didn't know, so they can start folded.
export function mergeIndex(local, remote) {
  const steps = {...remote.steps}
  for (const [ref, n] of Object.entries(local.steps)) steps[ref] = Math.min(n, steps[ref] ?? n)

  const byStart = new Map(local.groups.map(g => [g[0], g]))
  const added = []
  for (const g of remote.groups) {
    const mine = byStart.get(g[0])
    if (!mine) {
      byStart.set(g[0], g)
      added.push(g)
    } else if (mine[1] === null && g[1] !== null) byStart.set(g[0], g)
  }
  const groups = [...byStart.values()].sort((a, b) => a[0] - b[0])

  const byN = new Map(remote.annotations.map(a => [a.n, a]))
  for (const a of local.annotations) byN.set(a.n, a)
  const annotations = [...byN.values()].sort((a, b) => a.n - b.n).slice(0, MAX_ANNOTATIONS)

  return {index: {steps, groups, annotations}, added}
}
