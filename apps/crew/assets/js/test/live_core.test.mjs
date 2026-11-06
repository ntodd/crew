// The run page's pure parts (§17.3): the clock and the hover card's
// controller. node --test assets/js/test
import {test} from "node:test"
import assert from "node:assert/strict"
import {formatDuration, ServerClock, HoverController} from "../live_core.js"

test("durations read like JobStatus.format", () => {
  assert.equal(formatDuration(0), "0s")
  assert.equal(formatDuration(59), "59s")
  assert.equal(formatDuration(60), "1m 00s")
  assert.equal(formatDuration(61), "1m 01s")
  assert.equal(formatDuration(3599), "59m 59s")
  assert.equal(formatDuration(3600), "1h 00m")
  assert.equal(formatDuration(3661), "1h 01m")
  assert.equal(formatDuration(-3), "0s")
})

test("the clock runs from the server's time, and only a new server time resets it", () => {
  let mono = 1000
  const clock = new ServerClock(() => mono)
  clock.sync("2026-11-03T10:00:00Z")
  const t0 = Date.parse("2026-11-03T10:00:00Z")
  assert.equal(clock.now(), t0)
  mono += 14_000
  assert.equal(clock.now(), t0 + 14_000)
  // A patch that didn't change the server's time leaves it running.
  clock.sync("2026-11-03T10:00:00Z")
  assert.equal(clock.now(), t0 + 14_000)
  // A new render recalibrates.
  clock.sync("2026-11-03T10:00:15Z")
  assert.equal(clock.now(), t0 + 15_000)
  mono += 1000
  assert.equal(clock.now(), t0 + 16_000)
})

test("a clock with no server time falls back to the browser's", () => {
  const clock = new ServerClock(() => 0)
  clock.sync(undefined)
  assert.ok(Math.abs(clock.now() - Date.now()) < 1000)
})

// Timers that only fire when told to.
function timers() {
  let next = 1
  const pending = new Map()
  return {
    setTimeout: (fn, ms) => (pending.set(next, {fn, ms}), next++),
    clearTimeout: id => pending.delete(id),
    run() {
      const all = [...pending.values()]
      pending.clear()
      for (const t of all) t.fn()
    },
    get size() {
      return pending.size
    },
  }
}

function card() {
  const t = timers()
  const log = []
  const hc = new HoverController({
    show: a => log.push(`show ${a}`),
    hide: () => log.push("hide"),
    setTimeout: t.setTimeout,
    clearTimeout: t.clearTimeout,
  })
  return {hc, t, log}
}

test("hovering opens after a moment; leaving first opens nothing", () => {
  const {hc, t, log} = card()
  hc.enter("a")
  assert.deepEqual(log, [])
  t.run()
  assert.deepEqual(log, ["show a"])
  assert.equal(hc.anchor, "a")

  const other = card()
  other.hc.enter("a")
  other.hc.leave("a")
  other.t.run()
  assert.deepEqual(other.log, [])
})

test("the pointer can move from the trigger into the card and back out", () => {
  const {hc, t, log} = card()
  hc.enter("a")
  t.run()
  hc.leave("a")
  hc.enterCard()
  t.run()
  assert.deepEqual(log, ["show a"])
  hc.leaveCard()
  t.run()
  assert.deepEqual(log, ["show a", "hide"])
  assert.equal(hc.anchor, null)
})

test("focus opens at once, and the pointer leaving doesn't close a focused trigger's card", () => {
  const {hc, t, log} = card()
  hc.focus("a")
  assert.deepEqual(log, ["show a"])
  hc.enter("a")
  hc.leave("a")
  t.run()
  assert.deepEqual(log, ["show a"])
  hc.blur("a")
  t.run()
  assert.deepEqual(log, ["show a", "hide"])
})

test("Escape or a scroll closes it, and cancels an opening still on its way", () => {
  const {hc, t, log} = card()
  hc.enter("a")
  hc.dismiss()
  t.run()
  assert.deepEqual(log, [])
  hc.focus("a")
  hc.dismiss()
  assert.deepEqual(log, ["show a", "hide"])
  assert.equal(t.size, 0)
})

test("one card, shared: moving to another trigger moves the card to it", () => {
  const {hc, t, log} = card()
  hc.enter("a")
  t.run()
  hc.leave("a")
  hc.enter("b")
  t.run()
  assert.deepEqual(log, ["show a", "show b"])
  assert.equal(hc.anchor, "b")
})

test("a trigger that goes away takes its pending opening, or its open card, with it", () => {
  const {hc, t, log} = card()
  hc.enter("a")
  hc.remove("a")
  t.run()
  assert.deepEqual(log, [])

  hc.focus("b")
  hc.remove("b")
  assert.deepEqual(log, ["show b", "hide"])
  assert.equal(t.size, 0)
})

test("timers are called as plain functions, as a browser's must be", () => {
  // window.setTimeout throws "Illegal invocation" called on anything else.
  const calls = []
  const strict = {
    setTimeout: function (fn, ms) {
      if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation")
      calls.push(ms)
      return 1
    },
    clearTimeout: function () {
      if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation")
    },
  }
  const hc = new HoverController({show: () => {}, hide: () => {}, ...strict})
  hc.enter("a")
  hc.leave("a")
  assert.deepEqual(calls, [150, 120])
})

test("a server time that arrives late doesn't take the clock backwards", () => {
  let mono = 0
  const clock = new ServerClock(() => mono)
  clock.sync("2026-11-03T10:00:00Z")
  const t0 = Date.parse("2026-11-03T10:00:00Z")
  mono += 8000
  clock.sync("2026-11-03T10:00:05Z")
  assert.equal(clock.now(), t0 + 8000)
  mono += 1000
  assert.equal(clock.now(), t0 + 9000)
  // One that's ahead still moves it on.
  clock.sync("2026-11-03T10:00:12Z")
  assert.equal(clock.now(), t0 + 12_000)
})
