import assert from "node:assert/strict"
import test from "node:test"

let importCounter = 0

async function importFreshBoot() {
  const url = new URL(`./boot.js?test=${importCounter++}`, import.meta.url)
  return import(url.href)
}

function installBrowserGlobals({readyState = "loading", csrfToken = "csrf-token"} = {}) {
  const documentListeners = []
  const windowListeners = []
  const constructedLiveSockets = []
  const mutationObservers = []
  const liveViewDebugLogs = []

  class Socket {}

  class MutationObserver {
    constructor(callback) {
      this.callback = callback
      mutationObservers.push(this)
    }

    observe(target, options) {
      this.target = target
      this.options = options
    }

    disconnect() {}
  }

  class LiveSocket {
    constructor(path, socket, options) {
      this.path = path
      this.socket = socket
      this.options = options
      this.connected = false
      this.debugDisabled = false
      this.pushedEvents = []
      this.phoenixSocket = {
        decode(message, callback) {
          callback(message)
        }
      }
      constructedLiveSockets.push(this)
    }

    getSocket() {
      return this.phoenixSocket
    }

    receive(message, route) {
      this.phoenixSocket.decode(message, route)
    }

    disableDebug() {
      this.debugDisabled = true
    }

    connect() {
      if (!this.debugDisabled) liveViewDebugLogs.push("update:")
      this.connected = true

      // Phoenix LiveView registers its top-level bubble listeners from
      // connect(), after boot.js has installed the AshUi capture
      // listeners. Keep both key and click paths here so the harness exercises
      // production listener registration order.
      for (const eventName of ["keydown", "click"]) {
        window.addEventListener(eventName, event => {
          let target = event.target
          const binding = this.binding(eventName)

          while (target && !target?.getAttribute?.(binding)) {
            target = target.parentElement || null
          }

          const phxEvent = target?.getAttribute?.(binding)
          const matchKey =
            eventName === "keydown" ? target?.getAttribute?.(this.binding("key")) : null

          if (
            !phxEvent ||
            (matchKey && matchKey.toLowerCase() !== event.key?.toLowerCase())
          ) {
            return
          }

          const value = {
            ...(eventName === "keydown" ? {key: event.key} : {}),
            ...this.options.metadata[eventName](event, target)
          }

          // Mirrors LiveView View.extractMeta: the target property is assembled
          // after the configured metadata callback returns.
          if (target.value !== undefined) value.value = target.value

          this.pushedEvents.push({type: eventName, event: phxEvent, value})
        })
      }
    }

    binding(name) {
      return `phx-${name}`
    }
  }

  const document = {
    readyState,
    activeElement: null,
    addEventListener(name, callback, options) {
      documentListeners.push({name, callback, options})
    },
    querySelector(selector) {
      if (selector !== 'meta[name="csrf-token"]') return null

      return {
        getAttribute(name) {
          return name === "content" ? csrfToken : null
        }
      }
    }
  }

  const window = {
    document,
    Phoenix: {Socket},
    LiveView: {LiveSocket},
    queueMicrotask,
    addEventListener(name, callback, options) {
      windowListeners.push({name, callback, options})
    }
  }

  globalThis.window = window
  globalThis.document = document
  globalThis.MutationObserver = MutationObserver

  return {
    Socket,
    constructedLiveSockets,
    liveViewDebugLogs,
    document,
    documentListeners,
    mutationObservers,
    window,
    windowListeners
  }
}

function restoreBrowserGlobals() {
  delete globalThis.window
  delete globalThis.document
  delete globalThis.MutationObserver
}

test("real patch callbacks mark receive, apply, and post-frame paint legs", async () => {
  restoreBrowserGlobals()
  const {createAshUiPatchInstrumentation} = await importFreshBoot()
  const marks = []
  const measures = []
  const frames = []
  const tasks = []
  const performance = {
    mark(name, options) {
      marks.push({name, detail: options?.detail})
    },
    measure(name, optionsOrStart, end) {
      measures.push({name, optionsOrStart, end})
    },
    clearMarks() {}
  }

  const instrumentation = createAshUiPatchInstrumentation({
    performance,
    requestAnimationFrame: callback => frames.push(callback),
    scheduleTask: callback => tasks.push(callback)
  })

  instrumentation.received({event: "heartbeat", payload: {}})
  instrumentation.received({event: "diff", payload: {}})
  instrumentation.received({event: "phx_reply", payload: {response: {diff: {}}}})
  instrumentation.received({event: "diff", payload: {e: [["noop", {}]], r: {}, t: "title"}})
  instrumentation.received({
    event: "phx_reply",
    payload: {response: {diff: {0: "search results"}}}
  })
  instrumentation.applyStarted()
  instrumentation.applyEnded()

  assert.deepEqual(marks.map(entry => entry.name), [
    "ash-ui:patch-receive",
    "ash-ui:patch-apply-start",
    "ash-ui:patch-apply-end"
  ])
  assert.deepEqual(measures.map(entry => entry.name), [
    "ash-ui:patch-receive-to-apply",
    "ash-ui:patch-apply"
  ])

  frames.shift()()
  tasks.shift()()

  assert.deepEqual(marks, [
    {name: "ash-ui:patch-receive", detail: {id: 1}},
    {name: "ash-ui:patch-apply-start", detail: {id: 1}},
    {name: "ash-ui:patch-apply-end", detail: {id: 1}},
    {name: "ash-ui:patch-frame", detail: {id: 1}},
    {name: "ash-ui:patch-paint", detail: {id: 1}}
  ])
  assert.deepEqual(measures.map(entry => entry.name), [
    "ash-ui:patch-receive-to-apply",
    "ash-ui:patch-apply",
    "ash-ui:patch-apply-to-frame",
    "ash-ui:patch-apply-to-paint",
    "ash-ui:patch-receive-to-paint",
    "ash-ui:patch-frame-to-paint"
  ])
})

test("boot marks patch receipt before Phoenix routes the decoded message", async () => {
  restoreBrowserGlobals()
  performance.clearMarks()
  performance.clearMeasures()
  const env = installBrowserGlobals()
  const {bootAshUiLiveSocket} = await importFreshBoot()
  const liveSocket = bootAshUiLiveSocket()

  liveSocket.receive(
    {event: "diff", payload: {0: "search results"}},
    () => {
      liveSocket.options.dom.onPatchStart()
      liveSocket.options.dom.onPatchEnd()
    }
  )

  const receive = performance.getEntriesByName("ash-ui:patch-receive").at(-1)
  const applyStart = performance.getEntriesByName("ash-ui:patch-apply-start").at(-1)
  const receiveToApply = performance
    .getEntriesByName("ash-ui:patch-receive-to-apply")
    .at(-1)

  assert.ok(receive.startTime <= applyStart.startTime)
  assert.ok(receiveToApply.duration >= 0)
  assert.equal(env.constructedLiveSockets[0], liveSocket)

  restoreBrowserGlobals()
})

function dispatchWindowEvent(env, name, event) {
  for (const listener of env.windowListeners.filter(candidate => candidate.name === name)) {
    listener.callback(event)
  }
}

async function dispatchWindowEventLikeBrowser(env, name, event) {
  const listeners = env.windowListeners.filter(candidate => candidate.name === name)

  for (const listener of listeners.filter(candidate =>
    candidate.options === true || candidate.options?.capture === true
  )) {
    listener.callback(event)
  }

  // Chromium performs the microtask checkpoint observed between AshUi's
  // window-capture handlers and LiveView's window-bubble key handler.
  await Promise.resolve()

  for (const listener of listeners.filter(candidate =>
    candidate.options !== true && candidate.options?.capture !== true
  )) {
    listener.callback(event)
  }
}

function resetObserver(env) {
  return env.mutationObservers.find(observer =>
    observer.options?.attributeFilter?.includes("value")
  )
}

function composerFixture(env) {
  const attributes = new Map([
    ["name", "composer_text"],
    ["value", ""],
    ["phx-change", "change"],
    ["phx-keydown", "keydown"],
    ["phx-key", "Enter"]
  ])

  const form = {
    tagName: "FORM",
    getAttribute(name) {
      return name === "phx-submit" ? "submit" : null
    },
    querySelectorAll(selector) {
      if (
        selector === "input[value],textarea[value],select[value]" ||
        selector === "textarea[data-ash-ui-key='Enter'],input[data-ash-ui-key='Enter']"
      ) {
        return [control]
      }

      return []
    }
  }

  const control = {
    tagName: "TEXTAREA",
    type: "textarea",
    value: "",
    form,
    ownerDocument: env.document,
    parentElement: form,
    getAttribute(name) {
      return attributes.get(name) ?? null
    },
    setAttribute(name, value) {
      attributes.set(name, String(value))
    },
    closest(selector) {
      return selector === "form" ? form : null
    }
  }

  const clickButton = {
    tagName: "BUTTON",
    form,
    parentElement: form,
    getAttribute(name) {
      return name === "phx-click" ? "click" : null
    },
    closest(selector) {
      return selector === "form" ? form : null
    }
  }

  const clickTarget = {
    tagName: "SPAN",
    parentElement: clickButton
  }

  const root = {
    tagName: "SECTION",
    addEventListener() {},
    getAttribute() {
      return null
    },
    matches() {
      return false
    },
    querySelector() {
      return null
    },
    querySelectorAll(selector) {
      if (selector === "input[value],textarea[value],select[value]") return [control]
      return []
    }
  }

  env.document.activeElement = control

  return {
    attributes,
    clickButton,
    clickTarget,
    control,
    form,
    root,
    fill(value) {
      control.value = value
      dispatchWindowEvent(env, "input", {type: "input", target: control})
    }
  }
}

test("registers module runtimes before DOMContentLoaded and boots one LiveSocket", async () => {
  const calls = []
  const env = installBrowserGlobals()

  try {
    const boot = await importFreshBoot()
    boot.registerRuntime({
      install() {
        calls.push("runtime:install")
      },
      hooks: {
        AgentHook: {
          mounted() {
            calls.push("runtime:mounted")
          }
        }
      }
    })

    assert.equal(env.constructedLiveSockets.length, 0)

    const dcl = env.documentListeners.find(listener => listener.name === "DOMContentLoaded")
    assert.ok(dcl)
    assert.deepEqual(dcl.options, {once: true})

    dcl.callback()

    assert.equal(env.constructedLiveSockets.length, 1)

    const liveSocket = env.constructedLiveSockets[0]
    assert.equal(liveSocket.path, "/live")
    assert.equal(liveSocket.socket, env.Socket)
    assert.deepEqual(liveSocket.options.params, {_csrf_token: "csrf-token"})
    assert.deepEqual(Object.keys(liveSocket.options.metadata).sort(), [
      "change",
      "click",
      "contextmenu",
      "input",
      "keydown",
      "keyup",
      "submit"
    ])

    for (const extractor of Object.values(liveSocket.options.metadata)) {
      assert.equal(typeof extractor, "function")
    }
    assert.equal(typeof liveSocket.options.hooks.AshUiClient.mounted, "function")
    assert.equal(typeof liveSocket.options.hooks.AgentHook.mounted, "function")
    assert.equal(liveSocket.debugDisabled, true)
    assert.equal(liveSocket.connected, true)
    assert.deepEqual(env.liveViewDebugLogs, [])
    assert.equal(env.window.liveSocket, liveSocket)
    assert.equal(liveSocket.__ashUiDomEventBridgeInstalled, true)
    assert.ok(env.windowListeners.some(listener => listener.name === "contextmenu"))
    assert.deepEqual(calls, ["runtime:install"])

    liveSocket.options.hooks.AgentHook.mounted()
    assert.deepEqual(calls, ["runtime:install", "runtime:mounted"])

    assert.equal(boot.bootAshUiLiveSocket(), liveSocket)
    assert.equal(env.constructedLiveSockets.length, 1)
  } finally {
    restoreBrowserGlobals()
  }
})

test("in-page island lifecycle and emit use the production LiveSocket hook topology", async () => {
  const env = installBrowserGlobals()
  const propsCalls = []
  const destroyCalls = []
  const disconnectedCalls = []
  const reconnectedCalls = []
  const pushedEvents = []
  const attributes = new Map([
    ["data-ash-ui-island", "contract-island"],
    ["data-ash-ui-island-props", JSON.stringify({count: 1, rev: 0})],
    [
      "data-ash-ui-island-events",
      JSON.stringify({changed: "v.island-changed"})
    ],
    ["phx-hook", "AshUiIsland"],
    ["phx-update", "ignore"]
  ])
  const clientOwnedChild = {pointerCaptureActive: true}
  const root = {
    children: [clientOwnedChild],
    getAttribute(name) {
      return attributes.get(name) ?? null
    }
  }

  try {
    const boot = await importFreshBoot()

    boot.registerIsland("contract-island", {
      onProps(props, meta) {
        propsCalls.push({props, meta})
      },
      onDestroy(meta) {
        destroyCalls.push(meta)
      },
      onDisconnected(meta) {
        disconnectedCalls.push(meta)
      },
      onReconnected(meta) {
        reconnectedCalls.push(meta)
      }
    })

    env.documentListeners.find(listener => listener.name === "DOMContentLoaded").callback()

    const hook = env.constructedLiveSockets[0].options.hooks.AshUiIsland
    const hookContext = {
      el: root,
      pushEvent(event, payload) {
        pushedEvents.push({event, payload})
      }
    }

    hook.mounted.call(hookContext)

    assert.deepEqual(propsCalls.map(call => call.props), [{count: 1, rev: 0}])
    assert.equal(propsCalls[0].meta.name, "contract-island")
    assert.equal(propsCalls[0].meta.root, root)
    assert.equal(propsCalls[0].meta.initial, true)

    boot.emitIsland("contract-island", "changed", {
      count: 2,
      base_rev: 0
    })

    assert.deepEqual(pushedEvents, [
      {
        event: "ash_ui:dispatch",
        payload: {
          binding: "v.island-changed",
          count: 2,
          base_rev: 0
        }
      }
    ])

    // LiveView's ignored-root patch updates the data payload on the same
    // keyed node. The client-owned child (and its active pointer capture)
    // remains untouched while the hook observes the new props.
    attributes.set(
      "data-ash-ui-island-props",
      JSON.stringify({count: 2, rev: 1})
    )
    hook.updated.call(hookContext)

    assert.equal(root.getAttribute("phx-update"), "ignore")
    assert.equal(root.children[0], clientOwnedChild)
    assert.equal(root.children[0].pointerCaptureActive, true)
    assert.deepEqual(propsCalls.map(call => call.props), [
      {count: 1, rev: 0},
      {count: 2, rev: 1}
    ])
    assert.equal(propsCalls[1].meta.initial, false)

    hook.updated.call(hookContext)
    assert.equal(propsCalls.length, 2, "unchanged props must not notify twice")

    hook.disconnected.call(hookContext)
    assert.equal(disconnectedCalls.length, 1)
    assert.equal(disconnectedCalls[0].name, "contract-island")
    assert.equal(disconnectedCalls[0].root, root)

    hook.reconnected.call(hookContext)
    assert.equal(reconnectedCalls.length, 1)
    assert.equal(reconnectedCalls[0].name, "contract-island")
    assert.equal(reconnectedCalls[0].root, root)

    hook.destroyed.call(hookContext)
    assert.equal(destroyCalls.length, 1)
    assert.equal(destroyCalls[0].name, "contract-island")
    assert.equal(destroyCalls[0].root, root)
  } finally {
    restoreBrowserGlobals()
  }
})

test("boots after import when the document is already ready", async () => {
  const env = installBrowserGlobals({readyState: "complete"})

  try {
    await importFreshBoot()
    await new Promise(resolve => setTimeout(resolve, 0))

    assert.equal(env.constructedLiveSockets.length, 1)
    assert.equal(env.constructedLiveSockets[0].connected, true)
    assert.equal(env.window.liveSocket, env.constructedLiveSockets[0])
  } finally {
    restoreBrowserGlobals()
  }
})

test("an interactive document waits for DOMContentLoaded so deferred runtimes can register", async () => {
  const env = installBrowserGlobals({readyState: "interactive"})

  try {
    await importFreshBoot()
    await new Promise(resolve => setTimeout(resolve, 0))

    assert.equal(env.constructedLiveSockets.length, 0)

    const dcl = env.documentListeners.find(listener => listener.name === "DOMContentLoaded")
    assert.ok(dcl)
    dcl.callback()

    assert.equal(env.constructedLiveSockets.length, 1)
    assert.equal(env.constructedLiveSockets[0].connected, true)
  } finally {
    restoreBrowserGlobals()
  }
})

test("can retry booting when Phoenix globals are not ready yet", async () => {
  const env = installBrowserGlobals()
  const liveView = env.window.LiveView
  delete env.window.LiveView

  try {
    const boot = await importFreshBoot()

    const dcl = env.documentListeners.find(listener => listener.name === "DOMContentLoaded")
    dcl.callback()

    assert.equal(env.constructedLiveSockets.length, 0)
    assert.equal(env.window.liveSocket, undefined)

    env.window.LiveView = liveView

    const liveSocket = boot.bootAshUiLiveSocket()
    assert.equal(env.constructedLiveSockets.length, 1)
    assert.equal(env.window.liveSocket, liveSocket)
  } finally {
    restoreBrowserGlobals()
  }
})

test("keydown and click metadata snapshot named controls from their enclosing form", async () => {
  const originalFormData = globalThis.FormData
  const env = installBrowserGlobals()

  globalThis.FormData = class {
    constructor(form) {
      this.form = form
    }

    entries() {
      return this.form.entries[Symbol.iterator]()
    }
  }

  try {
    await importFreshBoot()

    const dcl = env.documentListeners.find(listener => listener.name === "DOMContentLoaded")
    dcl.callback()

    const metadata = env.constructedLiveSockets[0].options.metadata
    const form = {
      entries: [
        ["composer_text", "fresh at dispatch"],
        ["tag", "one"],
        ["tag", "two"]
      ]
    }
    const control = {form}

    assert.deepEqual(
      metadata.keydown({
        target: {},
        key: "Enter",
        altKey: false,
        ctrlKey: false,
        metaKey: false,
        shiftKey: false
      }, control),
      {
        composer_text: "fresh at dispatch",
        tag: ["one", "two"],
        key: "Enter",
        alt: false,
        ctrl: false,
        meta: false,
        shift: false
      }
    )

    assert.deepEqual(
      metadata.click({
        target: {},
        button: 0,
        buttons: 1,
        altKey: false,
        ctrlKey: false,
        metaKey: false,
        shiftKey: false
      }, control),
      {
        composer_text: "fresh at dispatch",
        tag: ["one", "two"],
        button: 0,
        buttons: 1,
        alt: false,
        ctrl: false,
        meta: false,
        shift: false
      }
    )

    assert.deepEqual(
      metadata.keyup({
        target: {},
        key: "Enter",
        altKey: false,
        ctrlKey: false,
        metaKey: false,
        shiftKey: false
      }, control),
      {
        composer_text: "fresh at dispatch",
        tag: ["one", "two"],
        key: "Enter",
        alt: false,
        ctrl: false,
        meta: false,
        shift: false
      }
    )

    assert.deepEqual(
      metadata.click({
        target: {},
        button: 0,
        buttons: 1,
        altKey: false,
        ctrlKey: false,
        metaKey: false,
        shiftKey: false
      }),
      {
        button: 0,
        buttons: 1,
        alt: false,
        ctrl: false,
        meta: false,
        shift: false
      }
    )
  } finally {
    globalThis.FormData = originalFormData
    restoreBrowserGlobals()
  }
})

test("native submit reset keeps a newer focused draft and still clears an idle dispatch", async () => {
  const originalFormData = globalThis.FormData
  const env = installBrowserGlobals()
  const fixture = composerFixture(env)

  globalThis.FormData = class {
    constructor(form) {
      this.form = form
    }

    *entries() {
      yield ["composer_text", fixture.control.value]
    }
  }

  try {
    await importFreshBoot()

    env.documentListeners.find(listener => listener.name === "DOMContentLoaded").callback()

    const liveSocket = env.constructedLiveSockets[0]
    const hook = liveSocket.options.hooks.AshUiClient
    const hookContext = {el: fixture.root}
    hook.mounted.call(hookContext)

    fixture.fill("first")
    dispatchWindowEvent(env, "submit", {type: "submit", target: fixture.form})
    assert.deepEqual(liveSocket.options.metadata.submit({target: fixture.form}), {
      form: {composer_text: "first"}
    })

    fixture.fill("second")
    hook.updated.call(hookContext)
    dispatchWindowEvent(env, "submit", {type: "submit", target: fixture.form})

    assert.deepEqual(liveSocket.options.metadata.submit({target: fixture.form}), {
      form: {composer_text: "second"}
    })

    hook.updated.call(hookContext)
    assert.equal(fixture.control.value, "")

    await Promise.resolve()
    assert.equal(fixture.control.value, "")

    fixture.control.value = "server draft"
    fixture.attributes.set("value", "server draft")
    env.document.activeElement = fixture.control
    hook.updated.call(hookContext)
    fixture.attributes.set("value", "")
    hook.updated.call(hookContext)

    assert.equal(fixture.control.value, "")

    fixture.fill("external draft")
    env.document.activeElement = null
    hook.updated.call(hookContext)

    assert.equal(fixture.control.value, "")
  } finally {
    globalThis.FormData = originalFormData
    restoreBrowserGlobals()
  }
})

test("three rapid click snapshots survive hook and observer patches between fills", async () => {
  const originalFormData = globalThis.FormData
  const env = installBrowserGlobals()
  const fixture = composerFixture(env)

  globalThis.FormData = class {
    *entries() {
      yield ["composer_text", fixture.control.value]
    }
  }

  try {
    await importFreshBoot()

    env.documentListeners.find(listener => listener.name === "DOMContentLoaded").callback()

    const liveSocket = env.constructedLiveSockets[0]
    const metadata = liveSocket.options.metadata
    const hook = liveSocket.options.hooks.AshUiClient
    const hookContext = {el: fixture.root}
    const clickEvent = {
      type: "click",
      target: fixture.clickButton,
      button: 0,
      buttons: 1,
      altKey: false,
      ctrlKey: false,
      metaKey: false,
      shiftKey: false
    }
    hook.mounted.call(hookContext)

    const sent = []

    fixture.fill("one")
    dispatchWindowEvent(env, "click", clickEvent)
    sent.push(metadata.click(clickEvent, fixture.clickButton).composer_text)

    fixture.fill("two")
    hook.updated.call(hookContext)
    dispatchWindowEvent(env, "click", clickEvent)
    sent.push(metadata.click(clickEvent, fixture.clickButton).composer_text)

    fixture.fill("three")
    resetObserver(env).callback([
      {type: "attributes", target: fixture.control, attributeName: "value"}
    ])
    dispatchWindowEvent(env, "click", clickEvent)
    sent.push(metadata.click(clickEvent, fixture.clickButton).composer_text)

    assert.deepEqual(sent, ["one", "two", "three"])

    resetObserver(env).callback([
      {type: "attributes", target: fixture.control, attributeName: "value"}
    ])
    assert.equal(fixture.control.value, "")

    fixture.fill("repeat")
    dispatchWindowEvent(env, "click", clickEvent)
    assert.equal(metadata.click(clickEvent, fixture.clickButton).composer_text, "repeat")
    fixture.fill("repeat")
    resetObserver(env).callback([
      {type: "attributes", target: fixture.control, attributeName: "value"}
    ])

    assert.equal(fixture.control.value, "repeat")
  } finally {
    globalThis.FormData = originalFormData
    restoreBrowserGlobals()
  }
})

test("narrowed patches synchronize non-empty values and newly materialized controls", async () => {
  const env = installBrowserGlobals()
  const fixture = composerFixture(env)

  try {
    await importFreshBoot()
    env.documentListeners.find(listener => listener.name === "DOMContentLoaded").callback()

    const observer = resetObserver(env)
    assert.equal(observer.options.childList, true)

    fixture.attributes.set("value", "server prefill")
    env.document.activeElement = null
    observer.callback([
      {type: "attributes", target: fixture.control, attributeName: "value"}
    ])
    assert.equal(fixture.control.value, "server prefill")

    const insertedAttributes = new Map([["value", "conditional prefill"]])
    const inserted = {
      tagName: "TEXTAREA",
      type: "textarea",
      value: "",
      ownerDocument: env.document,
      getAttribute(name) {
        return insertedAttributes.get(name) ?? null
      },
      querySelectorAll() {
        return []
      }
    }

    observer.callback([{type: "childList", target: fixture.root, addedNodes: [inserted]}])
    assert.equal(inserted.value, "conditional prefill")
  } finally {
    restoreBrowserGlobals()
  }
})

test("production click response applies an authoritative focused composer update", async () => {
  const originalFormData = globalThis.FormData
  const env = installBrowserGlobals()
  const fixture = composerFixture(env)

  globalThis.FormData = class {
    *entries() {
      yield ["composer_text", fixture.control.value]
    }
  }

  try {
    await importFreshBoot()

    env.documentListeners.find(listener => listener.name === "DOMContentLoaded").callback()

    const liveSocket = env.constructedLiveSockets[0]
    const hook = liveSocket.options.hooks.AshUiClient
    const hookContext = {el: fixture.root}
    const click = {
      type: "click",
      target: fixture.clickTarget,
      detail: 1,
      button: 0,
      buttons: 1,
      altKey: false,
      ctrlKey: false,
      metaKey: false,
      shiftKey: false
    }

    hook.mounted.call(hookContext)
    fixture.fill("handoff")
    await dispatchWindowEventLikeBrowser(env, "click", click)

    assert.equal(liveSocket.pushedEvents.at(-1).type, "click")
    assert.equal(liveSocket.pushedEvents.at(-1).value.composer_text, "handoff")

    fixture.attributes.set("value", "handoff @Lin ")
    hook.updated.call(hookContext)

    assert.equal(fixture.control.value, "handoff @Lin ")

    fixture.fill("next draft")
    await dispatchWindowEventLikeBrowser(env, "click", click)
    fixture.fill("newer local edit")
    fixture.attributes.set("value", "next draft @Lin ")
    hook.updated.call(hookContext)

    assert.equal(fixture.control.value, "newer local edit")
  } finally {
    globalThis.FormData = originalFormData
    restoreBrowserGlobals()
  }
})

test("Enter's optimistic reset cannot clear text typed after dispatch", async () => {
  const originalFormData = globalThis.FormData
  const env = installBrowserGlobals()
  const fixture = composerFixture(env)

  globalThis.FormData = class {
    *entries() {
      yield ["composer_text", fixture.control.value]
    }
  }

  try {
    await importFreshBoot()

    env.documentListeners.find(listener => listener.name === "DOMContentLoaded").callback()

    const liveSocket = env.constructedLiveSockets[0]
    const metadata = liveSocket.options.metadata
    const keydown = {
      type: "keydown",
      target: fixture.control,
      key: "Enter",
      altKey: false,
      ctrlKey: false,
      metaKey: false,
      shiftKey: false
    }

    fixture.fill("first Enter")
    dispatchWindowEvent(env, "keydown", keydown)
    assert.equal(metadata.keydown(keydown, fixture.control).composer_text, "first Enter")

    fixture.fill("second Enter")
    await Promise.resolve()

    assert.equal(fixture.control.value, "second Enter")

    for (const modifier of ["shiftKey", "ctrlKey", "metaKey", "altKey"]) {
      dispatchWindowEvent(env, "keydown", {...keydown, [modifier]: true})
      await new Promise(resolve => setTimeout(resolve, 0))

      assert.equal(fixture.control.value, "second Enter")
    }
  } finally {
    globalThis.FormData = originalFormData
    restoreBrowserGlobals()
  }
})

test("production entrypoint snapshots a settled Enter before its optimistic reset", async () => {
  const originalFormData = globalThis.FormData
  const env = installBrowserGlobals()
  const fixture = composerFixture(env)

  globalThis.FormData = class {
    *entries() {
      yield ["composer_text", fixture.control.value]
    }
  }

  try {
    await importFreshBoot()

    env.documentListeners.find(listener => listener.name === "DOMContentLoaded").callback()

    const liveSocket = env.constructedLiveSockets[0]
    const keydown = {
      type: "keydown",
      target: fixture.control,
      key: "Enter",
      altKey: false,
      ctrlKey: false,
      metaKey: false,
      shiftKey: false
    }

    fixture.fill("single settled Enter")
    await dispatchWindowEventLikeBrowser(env, "keydown", keydown)

    assert.equal(liveSocket.pushedEvents.at(-1).value.composer_text, "single settled Enter")
    assert.equal(liveSocket.pushedEvents.at(-1).value.value, "single settled Enter")
    assert.equal(fixture.control.value, "single settled Enter")

    await new Promise(resolve => setTimeout(resolve, 0))
    assert.equal(fixture.control.value, "")
  } finally {
    globalThis.FormData = originalFormData
    restoreBrowserGlobals()
  }
})
