// The log viewer's pure parts (§17.6): node --test assets/js/test
import {test} from "node:test"
import assert from "node:assert/strict"
import {parseAnsi, Rows, indexAdd, annotationOf, fileLink, groupsToCollapse, firstErrorLine, nearest16, mergeIndex} from "../log_core.js"

test("SGR colours, 256 and 24-bit, map to classes; other escapes are stripped", () => {
  assert.deepEqual(parseAnsi("plain"), [{text: "plain", cls: ""}])
  assert.deepEqual(parseAnsi("\u001b[31mred\u001b[0m done"), [{text: "red", cls: "fg-1"}, {text: " done", cls: ""}])
  assert.deepEqual(parseAnsi("\u001b[1;92mbold green\u001b[22m"), [{text: "bold green", cls: "fg-10 b"}])
  assert.deepEqual(parseAnsi("\u001b[38;5;196mx"), [{text: "x", cls: "fg-9"}])
  assert.deepEqual(parseAnsi("\u001b[48;2;0;0;250my"), [{text: "y", cls: "bg-4"}])
  assert.deepEqual(parseAnsi("\u001b[2;3;4mz\u001b[39;49;0m"), [{text: "z", cls: "dim i u"}])
  // Cursor moves, OSC titles and the like vanish; the text stays.
  assert.deepEqual(parseAnsi("a\u001b[2Kb\u001b]0;title\u0007c"), [{text: "abc", cls: ""}])
  // A lone ESC can't inject anything.
  assert.deepEqual(parseAnsi("<b>\u001b</b>"), [{text: "<b></b>", cls: ""}])
})

test("nearest16 picks the palette colour", () => {
  assert.equal(nearest16(0, 0, 0), 0)
  assert.equal(nearest16(255, 255, 255), 15)
  assert.equal(nearest16(200, 10, 10), 1)
})

test("rows skip collapsed groups and map both ways", () => {
  const rows = new Rows(20)
  rows.collapse([[3, 8], [12, 13]])
  // Lines 4..8 and 13 are hidden; group headers stay.
  assert.equal(rows.count(), 20 - 5 - 1)
  assert.deepEqual([1, 2, 3, 4, 5].map(r => rows.lineAt(r)), [1, 2, 3, 9, 10])
  assert.equal(rows.rowOf(9), 4)
  assert.equal(rows.rowOf(6), 3) // a hidden line shows as its group's header
  rows.expand(3)
  assert.equal(rows.count(), 20 - 1)
  assert.equal(rows.lineAt(4), 4)
  rows.setTotal(25)
  assert.equal(rows.count(), 24)
})

test("an open group (no end yet) hides to the end of the log", () => {
  const rows = new Rows(10)
  rows.collapse([[5, null]])
  assert.equal(rows.count(), 5)
})

test("the index learns from appended lines like the server's", () => {
  const index = {steps: {}, groups: [], annotations: []}
  indexAdd(index, [
    {n: 1, step_ref: "s1", text: "::group::Install"},
    {n: 2, step_ref: "s1", text: "::endgroup::"},
    {n: 3, step_ref: "s2", text: "\u001b[31m::error file=a b.ex,line=3::boom\u001b[0m"},
    {n: 4, step_ref: "s2", text: "##[group]Next"},
  ])
  assert.deepEqual(index.steps, {s1: 1, s2: 3})
  assert.deepEqual(index.groups, [[1, 2, "Install"], [4, null, "Next"]])
  assert.deepEqual(index.annotations, [{n: 3, level: "error", text: "boom", file: "a b.ex", line: 3}])
})

test("annotations and their links: only the github.com blob form", () => {
  assert.deepEqual(annotationOf("::warning::careful"), {level: "warning", text: "careful", file: null, line: null})
  assert.equal(annotationOf("not ::error:: here"), null)
  assert.equal(
    fileLink("https://github.com", "acme/web", "abc123", "lib/a b.ex", 12),
    "https://github.com/acme/web/blob/abc123/lib/a%20b.ex#L12",
  )
  // Dot segments go, so a path can't climb out of the blob.
  assert.equal(fileLink("https://github.com", "acme/web", "abc123", "../../etc/passwd", 1), "https://github.com/acme/web/blob/abc123/etc/passwd#L1")
  assert.equal(fileLink("https://github.com", "acme/web", "abc123", "javascript:alert(1)", 1).startsWith("https://github.com/acme/web/blob/"), true)
  assert.equal(fileLink("https://github.com", "acme/web", null, "a.ex", 1), null)
})

test("groups start collapsed in finished steps and open in the running one", () => {
  const index = {steps: {s1: 1, s2: 10}, groups: [[2, 5, "a"], [11, 12, "b"], [13, null, "c"]], annotations: []}
  const steps = [{ref: "s1", status: "completed"}, {ref: "s2", status: "in_progress"}]
  assert.deepEqual(groupsToCollapse(index, steps, true), [[2, 5]])
  // While the job runs, a group whose step isn't known to be finished stays open.
  assert.deepEqual(groupsToCollapse(index, [], true), [])
  // A finished job folds every closed group.
  assert.deepEqual(groupsToCollapse(index, steps, false), [[2, 5], [11, 12]])
})

test("first error: the first ::error, else the last 50 lines of the failed step", () => {
  const steps = [{ref: "s1", conclusion: "success"}, {ref: "s2", conclusion: "failure"}, {ref: "s3", conclusion: null}]
  assert.equal(firstErrorLine({steps: {s1: 1, s2: 100, s3: 300}, annotations: [{n: 42, level: "warning"}, {n: 77, level: "error"}]}, steps, 400), 77)
  assert.equal(firstErrorLine({steps: {s1: 1, s2: 100, s3: 300}, annotations: []}, steps, 400), 250)
  assert.equal(firstErrorLine({steps: {s1: 1, s2: 100}, annotations: []}, steps.slice(0, 2), 120), 100)
  assert.equal(firstErrorLine({steps: {}, annotations: []}, [], 10), null)
})

test("an index from the server merges into what the viewer learned live", () => {
  const local = {steps: {s2: 30}, groups: [[40, null, "Live"]], annotations: [{n: 35, level: "error", text: "x"}]}
  const remote = {steps: {s1: 1, s2: 30}, groups: [[3, 9, "Install"], [40, 44, "Live"]], annotations: [{n: 11, level: "warning", text: "w"}]}
  const {index, added} = mergeIndex(local, remote)
  assert.deepEqual(index.steps, {s1: 1, s2: 30})
  assert.deepEqual(index.groups, [[3, 9, "Install"], [40, 44, "Live"]])
  assert.deepEqual(index.annotations.map(a => a.n), [11, 35])
  assert.deepEqual(added, [[3, 9, "Install"]])
  // A group the viewer has closed isn't reopened by a stale copy.
  const stale = mergeIndex({steps: {}, groups: [[5, 8, "A"]], annotations: []}, {steps: {}, groups: [[5, null, "A"]], annotations: []})
  assert.deepEqual(stale.index.groups, [[5, 8, "A"]])
})
