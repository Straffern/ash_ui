import assert from "node:assert/strict"
import test from "node:test"

import {createIslandRuntime} from "./island.js"

function root(name, props = {}, events = {change: `${name}.change`}) {
  const attributes = new Map([
    ["data-ash-ui-island", name],
    ["data-ash-ui-island-props", JSON.stringify(props)],
    ["data-ash-ui-island-events", JSON.stringify(events)]
  ])

  return {
    attributes,
    getAttribute(attribute) {
      return attributes.get(attribute) ?? null
    }
  }
}

function harness(options = {}) {
  let lifecycle
  const sends = []
  const binding = {
    observe(callbacks) {
      lifecycle = callbacks
    },
    send(root, binding, payload) {
      sends.push({root, binding, payload})
      return Promise.resolve({ok: true})
    }
  }

  const runtime = createIslandRuntime({binding, ...options})
  return {lifecycle, runtime, sends}
}

test("island.define closes emit over each root and late registration replays props", async () => {
  const {lifecycle, runtime, sends} = harness()
  const first = root("editor", {id: 1})
  const second = root("editor", {id: 2})
  const contexts = new Map()
  const props = []

  lifecycle.onAttach(first)
  lifecycle.onAttach(second)

  runtime.define("editor", {
    create(root, ctx) {
      contexts.set(root, ctx)
      return {
        props(value, meta) {
          props.push({root, value, initial: meta.initial})
        }
      }
    }
  })

  assert.deepEqual(props, [
    {root: first, value: {id: 1}, initial: true},
    {root: second, value: {id: 2}, initial: true}
  ])

  await contexts.get(first).emit("change", {value: "first"})
  await contexts.get(second).emit("change", {value: "second"})

  assert.deepEqual(sends, [
    {root: first, binding: "editor.change", payload: {value: "first"}},
    {root: second, binding: "editor.change", payload: {value: "second"}}
  ])
})

test("props use the encoded fast path and serialize async delivery before destroy", async () => {
  const {lifecycle, runtime} = harness()
  const islandRoot = root("queue", {rev: 1})
  const calls = []
  let finishFirst

  runtime.define("queue", {
    create() {
      return {
        props(value) {
          calls.push(`props:${value.rev}:start`)

          if (value.rev === 1) {
            return new Promise(resolve => {
              finishFirst = () => {
                calls.push("props:1:end")
                resolve()
              }
            })
          }

          calls.push(`props:${value.rev}:end`)
        },
        destroy() {
          calls.push("destroy")
        }
      }
    }
  })

  lifecycle.onAttach(islandRoot)
  lifecycle.onSync(islandRoot)
  assert.deepEqual(calls, ["props:1:start"], "unchanged encoded props must not enqueue")

  islandRoot.attributes.set("data-ash-ui-island-props", JSON.stringify({rev: 2}))
  lifecycle.onSync(islandRoot)
  const destroyed = lifecycle.onDetach(islandRoot, "terminal")

  assert.deepEqual(calls, ["props:1:start"])
  finishFirst()
  await destroyed

  assert.deepEqual(calls, [
    "props:1:start",
    "props:1:end",
    "props:2:start",
    "props:2:end",
    "destroy"
  ])
})

test("suspension, applying, holds, debounce, and unload drops are observable", async () => {
  const timers = new Map()
  let timerId = 0
  const clock = {
    setTimeout(callback) {
      timerId += 1
      timers.set(timerId, callback)
      return timerId
    },
    clearTimeout(id) {
      timers.delete(id)
    }
  }
  const listeners = new Map()
  const lifecycleTarget = {
    addEventListener(name, callback) {
      listeners.set(name, callback)
    },
    removeEventListener(name) {
      listeners.delete(name)
    }
  }
  const dropped = []
  const {lifecycle, runtime, sends} = harness({clock, lifecycleTarget})
  const islandRoot = root("debounced", {})
  let ctx

  runtime.define("debounced", {
    debounce: 75,
    emitWhile: "live",
    onEmitDropped(detail) {
      dropped.push(detail.reason)
    },
    create(_root, context) {
      ctx = context
      return {}
    }
  })

  lifecycle.onAttach(islandRoot)
  ctx.hold()
  const held = ctx.emit("change", {value: 1})
  assert.equal(timers.size, 0)

  ctx.release()
  assert.equal(timers.size, 1)
  const [firstTimer, firstCallback] = timers.entries().next().value
  timers.delete(firstTimer)
  firstCallback()
  await held
  assert.equal(sends.length, 1)

  lifecycle.onSuspend(islandRoot)
  assert.equal(ctx.suspended, true)
  assert.deepEqual(await ctx.emit("change", {value: 2}), {
    dropped: true,
    reason: "suspended"
  })

  lifecycle.onResume(islandRoot)
  const pending = ctx.emit("change", {value: 3})
  assert.equal(timers.size, 1)
  listeners.get("pagehide")()
  assert.deepEqual(await pending, {dropped: true, reason: "unloading"})
  assert.equal(listeners.size, 0)
  assert.deepEqual(dropped, ["suspended", "unloading"])
})

test("flush sends a pending emission on the caller's own stack, ahead of a later emit", async () => {
  const timers = new Map()
  let timerId = 0
  const clock = {
    setTimeout(callback) {
      timerId += 1
      timers.set(timerId, callback)
      return timerId
    },
    clearTimeout(id) {
      timers.delete(id)
    }
  }
  const {lifecycle, runtime, sends} = harness({
    clock,
    lifecycleTarget: {addEventListener() {}, removeEventListener() {}}
  })
  const islandRoot = root("flusher", {}, {slow: "flusher.slow", fast: "flusher.fast"})
  let ctx

  runtime.define("flusher", {
    debounce: {slow: 75},
    create(_root, context) {
      ctx = context
      return {}
    }
  })

  lifecycle.onAttach(islandRoot)
  const pending = ctx.emit("slow", {value: 1})
  assert.equal(timers.size, 1, "a debounced emission waits for its window")
  assert.equal(sends.length, 0)

  // The adapter is racing an echo it is about to provoke synchronously, so the flushed
  // send must already have happened when flush() returns — not one microtask later.
  ctx.flush("slow")
  assert.deepEqual(
    sends.map(send => send.binding),
    ["flusher.slow"],
    "flush sends synchronously"
  )
  assert.equal(timers.size, 0, "the debounce timer is cleared with it")

  ctx.emit("fast", {value: 2})
  assert.deepEqual(sends.map(send => send.binding), ["flusher.slow", "flusher.fast"])
  assert.deepEqual(await pending, {ok: true})
})

test("clearPending drops the pending emission without disturbing the gating", async () => {
  const timers = new Map()
  let timerId = 0
  const clock = {
    setTimeout(callback) {
      timerId += 1
      timers.set(timerId, callback)
      return timerId
    },
    clearTimeout(id) {
      timers.delete(id)
    }
  }
  const dropped = []
  const {lifecycle, runtime, sends} = harness({
    clock,
    lifecycleTarget: {addEventListener() {}, removeEventListener() {}}
  })
  const islandRoot = root("clearer", {})
  let ctx

  runtime.define("clearer", {
    debounce: 75,
    onEmitDropped(detail) {
      dropped.push(detail.reason)
    },
    create(_root, context) {
      ctx = context
      return {}
    }
  })

  lifecycle.onAttach(islandRoot)
  ctx.hold()
  const held = ctx.emit("change", {value: 1})
  ctx.clearPending("obsolete")
  assert.deepEqual(await held, {dropped: true, reason: "obsolete"})
  assert.deepEqual(dropped, ["obsolete"])

  // The hold this context did not take is still in force: a fresh emission stays held.
  ctx.emit("change", {value: 2})
  assert.equal(timers.size, 0, "still held")
  assert.equal(sends.length, 0)

  ctx.release()
  assert.equal(timers.size, 1, "one release still ends the hold clearPending never took")
  timers.entries().next().value[1]()
  await Promise.resolve()
  assert.equal(sends.length, 1)
})

test("an island's context carries the host affordances its adapter offers, and only those", async () => {
  const calls = []
  const host = {
    capabilities: {downloadFile: true, sendMessage: false},
    downloadFile: (params) => (calls.push(["downloadFile", params]), {ok: 1}),
    sendMessage: (params) => (calls.push(["sendMessage", params]), {}),
    updateModelContext: (params) => (calls.push(["updateModelContext", params]), {updateId: "u1"}),
    secret: "the adapter's own state"
  }
  const {lifecycle, runtime} = harness({host})
  const element = root("viewer")
  lifecycle.onAttach(element)
  let ctx
  runtime.define("viewer", {create(_root, context) { ctx = context; return {} }})

  assert.equal(Object.isFrozen(ctx.host), true)
  // A method whose capability the host declared false is not offered; one it did not mention is.
  assert.deepEqual(Object.keys(ctx.host).sort(),
    ["capabilities", "downloadFile", "updateModelContext"])
  assert.equal(ctx.host.secret, undefined)
  assert.equal(ctx.host.sendMessage, undefined)
  assert.deepEqual(ctx.host.capabilities,
    {downloadFile: true, sendMessage: false, updateModelContext: true})
  assert.deepEqual(await ctx.host.updateModelContext({content: [{type: "text", text: "view"}]}),
    {updateId: "u1"})
  await ctx.host.downloadFile({contents: []})
  assert.deepEqual(calls.map(([name]) => name), ["updateModelContext", "downloadFile"])
})

test("an island mounted without a host gets none, and a malformed host is refused", () => {
  const {lifecycle, runtime} = harness()
  const element = root("plain")
  lifecycle.onAttach(element)
  let ctx
  runtime.define("plain", {create(_root, context) { ctx = context; return {} }})
  assert.equal(ctx.host, undefined)
  assert.throws(() => harness({host: {downloadFile: "not a function"}}),
    /host\.downloadFile must be a function/)
  assert.throws(() => harness({host: "nope"}), /host must be an object/)
})

test("the capability gate binds: a declared-false capability withholds its method, a declared-true one needs a method", async () => {
  const {lifecycle, runtime} = harness({host: {
    capabilities: {downloadFile: false, sendMessage: true, updateModelContext: true},
    downloadFile: () => ({}),
    updateModelContext: () => ({})
  }})
  const element = root("gated")
  lifecycle.onAttach(element)
  let ctx
  runtime.define("gated", {create(_root, context) { ctx = context; return {} }})
  assert.equal(ctx.host.downloadFile, undefined)
  assert.equal(ctx.host.sendMessage, undefined)
  assert.equal(typeof ctx.host.updateModelContext, "function")
  assert.deepEqual(ctx.host.capabilities,
    {downloadFile: false, sendMessage: false, updateModelContext: true})
})

test("an affordance runs the adapter's method on the adapter, at call time", async () => {
  const host = {
    label: "first",
    downloadFile() { return {label: this.label} }
  }
  const {lifecycle, runtime} = harness({host})
  const element = root("bound")
  lifecycle.onAttach(element)
  let ctx
  runtime.define("bound", {create(_root, context) { ctx = context; return {} }})
  host.label = "second"
  assert.deepEqual(await ctx.host.downloadFile({contents: []}), {label: "second"})
})
