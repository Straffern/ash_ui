import assert from "node:assert/strict"
import test from "node:test"

import {
  attachAshUiRuntime,
  createAshUiClientHooks,
  installAshUiDomCommandBridge,
  installLiveViewInputPushBackpressure,
  requestAshUiScrollIntoView
} from "./client.js"

function asyncRevealHarness() {
  const targets = new Map()
  const observers = []
  const timers = []
  const events = []
  const bodyChildren = []

  class FakeMutationObserver {
    constructor(callback) {
      this.callback = callback
      this.disconnected = false
      observers.push(this)
    }

    observe() {}

    disconnect() {
      this.disconnected = true
    }
  }

  class FakeCustomEvent {
    constructor(type, options) {
      this.type = type
      this.detail = options?.detail
    }
  }

  const document = {
    documentElement: {},
    body: {
      prepend(element) {
        bodyChildren.unshift(element)
      }
    },
    querySelector(selector) {
      if (selector === '[part~="document_notice"]') {
        return bodyChildren.find(element => element.getAttribute("part") === "document_notice")
      }

      return targets.get(selector) || null
    },
    getElementById(id) {
      return targets.get(`#${id}`) || null
    },
    createElement() {
      const attributes = new Map()

      return {
        hidden: false,
        textContent: "",
        setAttribute(name, value) {
          attributes.set(name, value)
        },
        getAttribute(name) {
          return attributes.get(name) || null
        },
        removeAttribute(name) {
          attributes.delete(name)
        },
        remove() {
          const index = bodyChildren.indexOf(this)
          if (index >= 0) bodyChildren.splice(index, 1)
        }
      }
    },
    dispatchEvent(event) {
      events.push(event)
    }
  }

  const runtime = {
    document,
    window: {CustomEvent: FakeCustomEvent},
    MutationObserver: FakeMutationObserver,
    setTimeout(callback) {
      const timer = {callback, cleared: false}
      timers.push(timer)
      return timer
    },
    clearTimeout(timer) {
      if (timer) timer.cleared = true
    },
    timeoutMs: 25
  }

  return {
    document,
    events,
    runtime,
    addPart(part, target) {
      targets.set(`[part~="${part}"]`, target)
    },
    mutate() {
      for (const observer of observers) observer.callback()
    },
    runTimers() {
      for (const timer of timers) {
        if (!timer.cleared) timer.callback()
      }
    }
  }
}

test("resolves a semantic part reveal and lets it override transcript follow", () => {
  const originalDocument = globalThis.document
  const originalWindow = globalThis.window
  const listeners = new Map()
  const stickBottom = {
    __ashUiAtBottom: true,
    __ashUiAnchorHeld: false,
  }
  const reveals = []
  const target = {
    closest(selector) {
      assert.equal(selector, "[data-stick-bottom]")
      return stickBottom
    },
    scrollIntoView(options) {
      reveals.push(options)
    },
  }

  globalThis.document = {
    querySelector(selector) {
      assert.equal(selector, '[part~="document_match"]')
      return target
    },
  }
  globalThis.window = {
    CSS: {escape: value => value},
    addEventListener(name, listener) {
      listeners.set(name, listener)
    },
  }

  try {
    installAshUiDomCommandBridge()
    listeners.get("phx:ash_ui:scroll-into-view")({
      detail: {
        part: "document_match",
        options: {block: "center", inline: "nearest"},
      },
    })

    assert.deepEqual(reveals, [{block: "center", inline: "nearest"}])
    assert.equal(stickBottom.__ashUiAnchorHeld, true)
    assert.equal(stickBottom.__ashUiAtBottom, false)
  } finally {
    globalThis.document = originalDocument
    globalThis.window = originalWindow
  }
})

test("retains an async reveal until content arrives and consumes it once", () => {
  const harness = asyncRevealHarness()
  const reveals = []
  const target = {
    closest() {
      return null
    },
    scrollIntoView(options) {
      reveals.push(options)
    }
  }

  assert.equal(
    requestAshUiScrollIntoView(
      {part: "late_match", options: {block: "center", inline: "nearest"}},
      harness.runtime
    ),
    "pending"
  )
  assert.deepEqual(reveals, [])

  harness.addPart("late_match", target)
  harness.mutate()

  assert.deepEqual(reveals, [{block: "center", inline: "nearest"}])

  // Later render mutations cannot replay a consumed reveal.
  harness.mutate()
  assert.equal(reveals.length, 1)
})

test("a newer anchor supersedes an unresolved async reveal", () => {
  const harness = asyncRevealHarness()
  const reveals = []
  const target = name => ({
    closest() {
      return null
    },
    scrollIntoView() {
      reveals.push(name)
    }
  })

  assert.equal(
    requestAshUiScrollIntoView({part: "old_match"}, harness.runtime),
    "pending"
  )
  assert.equal(
    requestAshUiScrollIntoView({part: "new_match"}, harness.runtime),
    "pending"
  )

  harness.addPart("old_match", target("old"))
  harness.mutate()
  assert.deepEqual(reveals, [])

  harness.addPart("new_match", target("new"))
  harness.mutate()
  assert.deepEqual(reveals, ["new"])
})

test("an unresolved bounded reveal surfaces a visible viewer notice", () => {
  const harness = asyncRevealHarness()

  assert.equal(
    requestAshUiScrollIntoView({part: "missing_match"}, harness.runtime),
    "pending"
  )

  harness.runTimers()

  const notice = harness.document.querySelector('[part~="document_notice"]')
  assert.equal(notice?.hidden, false)
  assert.equal(notice?.getAttribute("role"), "status")
  assert.equal(notice?.getAttribute("aria-live"), "polite")
  assert.equal(notice?.textContent, "The referenced content could not be revealed.")
  assert.equal(harness.events.length, 1)
  assert.equal(harness.events[0].type, "ash-ui:scroll-into-view-unresolved")
  assert.equal(harness.events[0].detail.reason, "target-timeout")
})

test("a 30ms 40-keystroke input burst keeps one push in flight and delivers the final value", async () => {
  const control = {type: "search", isConnected: true}
  const calls = []
  const consoleErrors = []
  let inFlight = 0
  let visibleQuery = null

  const view = {
    pushInput(_input, _targetContext, _cid, _event, opts, callback) {
      inFlight += 1

      if (inFlight > 1) {
        consoleErrors.push("Failed to push input event: timeout")
      }

      calls.push(opts.value)

      setTimeout(() => {
        inFlight -= 1
        callback?.({value: opts.value})
      }, 90)
    }
  }

  const liveSocket = {
    owner(_element, callback) {
      return callback ? callback(view) : view
    }
  }

  installLiveViewInputPushBackpressure(liveSocket)

  const startedAt = performance.now()

  for (let index = 0; index < 40; index++) {
    liveSocket.owner(control, owner =>
      owner.pushInput(
        control,
        control,
        null,
        "edit",
        {value: `query-${index}`},
        response => {
          visibleQuery = response.value
        }
      )
    )

    await new Promise(resolve => setTimeout(resolve, 30))
  }

  while (inFlight > 0) {
    await new Promise(resolve => setTimeout(resolve, 10))
  }

  assert.deepEqual(consoleErrors, [])
  assert.equal(calls.at(-1), "query-39")
  assert.equal(visibleQuery, "query-39")
  assert.ok(calls.length < 20, `expected a coalesced burst, got ${calls.length} pushes`)
  assert.ok(performance.now() - startedAt < 1_600, "final input reply did not recover promptly")
})

test("a runtime attached after boot composes in and retro-mounts live hook instances", () => {
  const makeRoot = marked => ({
    tagName: "DIV",
    __lateRuntimeTarget: marked,
    addEventListener() {},
    getAttribute() {
      return null
    },
    querySelectorAll() {
      return []
    }
  })

  const hooks = createAshUiClientHooks()
  const liveInstance = {el: makeRoot(true)}
  hooks.AshUiClient.mounted.call(liveInstance)

  const calls = []
  const runtime = {
    hooks: {
      AshUiClient: {
        mounted() {
          if (this.el?.__lateRuntimeTarget) calls.push(["mounted", this])
        },
        updated() {
          if (this.el?.__lateRuntimeTarget) calls.push(["updated", this])
        }
      }
    }
  }

  assert.equal(attachAshUiRuntime(runtime), true)

  // Retro-mounted onto the already-live instance.
  assert.deepEqual(calls, [["mounted", liveInstance]])

  // The live instance's lifecycle methods now include the runtime.
  assert.equal(typeof liveInstance.updated, "function")
  liveInstance.updated()
  assert.deepEqual(calls.at(-1), ["updated", liveInstance])

  // Future mounts compose the runtime through the shared hooks object.
  const nextInstance = {el: makeRoot(true)}
  hooks.AshUiClient.mounted.call(nextInstance)
  assert.deepEqual(calls.at(-1), ["mounted", nextInstance])

  // Destroyed instances stop receiving retro-mounts.
  hooks.AshUiClient.destroyed.call(liveInstance)
  hooks.AshUiClient.destroyed.call(nextInstance)
  const before = calls.length
  attachAshUiRuntime(runtime)
  assert.equal(calls.length, before)
})

test("composes AshUiClient lifecycles from runtimes in order", () => {
  const calls = []
  const hooks = createAshUiClientHooks({
    runtimes: [
      {
        install() {
          calls.push("agent:install")
        },
        hooks: {
          AshUiClient: {
            mounted() {
              calls.push(`agent:${this.id}:mounted`)
            },
            updated() {
              calls.push(`agent:${this.id}:updated`)
            }
          }
        }
      },
      {
        hooks: {
          AshUiClient: {
            mounted() {
              calls.push(`host:${this.id}:mounted`)
            },
            destroyed() {
              calls.push(`host:${this.id}:destroyed`)
            }
          }
        }
      }
    ]
  })

  const context = {id: "root"}

  hooks.AshUiClient.mounted.call(context)
  hooks.AshUiClient.updated.call(context)
  hooks.AshUiClient.destroyed.call(context)

  assert.deepEqual(calls, [
    "agent:install",
    "agent:root:mounted",
    "host:root:mounted",
    "agent:root:updated",
    "host:root:destroyed"
  ])
})

test("keeps non-AshUi hooks", () => {
  const hooks = createAshUiClientHooks({
    runtimes: [
      {
        hooks: {
          AshUiClient: {
            mounted() {}
          },
          StaffAgentPanelShell: {
            mounted() {
              this.shellMounted = true
            }
          }
        }
      }
    ]
  })

  const context = {}

  hooks.StaffAgentPanelShell.mounted.call(context)

  assert.equal(context.shellMounted, true)
})

test("base hook synchronizes controlled descendants without replacing focused drafts", () => {
  const document = {activeElement: null}

  const serverControlled = {
    tagName: "TEXTAREA",
    type: "textarea",
    value: "",
    ownerDocument: document,
    getAttribute(name) {
      return name === "value" ? "server value" : null
    }
  }

  const focusedDraft = {
    tagName: "INPUT",
    type: "text",
    value: "local draft",
    ownerDocument: document,
    getAttribute(name) {
      return name === "value" ? "stale server value" : null
    }
  }

  document.activeElement = focusedDraft

  const root = {
    tagName: "SECTION",
    addEventListener() {},
    getAttribute() {
      return null
    },
    querySelectorAll(selector) {
      if (selector === "input[value],textarea[value],select[value]") {
        return [serverControlled, focusedDraft]
      }

      return []
    }
  }

  const hooks = createAshUiClientHooks()
  hooks.AshUiClient.mounted.call({el: root})

  assert.equal(serverControlled.value, "server value")
  assert.equal(focusedDraft.value, "local draft")
})

test("base hook dispatches component events through rendered AshUi bindings", () => {
  let listener
  let capturedEvent
  let capturedPayload
  let prevented = false
  let stopped = false

  const root = {
    addEventListener(name, callback) {
      if (name === "ash-ui:component-event") listener = callback
    }
  }

  const target = {
    getAttribute(name) {
      if (name === "phx-click") return "ash_ui:dispatch:root.save.click"
      return null
    }
  }

  const hooks = createAshUiClientHooks()

  hooks.AshUiClient.mounted.call({
    el: root,
    pushEvent(event, payload) {
      capturedEvent = event
      capturedPayload = payload
    }
  })

  listener({
    target,
    detail: {payload: {annotation_id: "ann-1"}},
    preventDefault() {
      prevented = true
    },
    stopPropagation() {
      stopped = true
    }
  })

  assert.equal(capturedEvent, "ash_ui:dispatch")
  assert.deepEqual(capturedPayload, {binding: "root.save.click", annotation_id: "ann-1"})
  assert.equal(prevented, true)
  assert.equal(stopped, true)
})

test("base hook dispatches component events through named AshUi bindings", () => {
  let listener
  let capturedPayload

  const root = {
    addEventListener(name, callback) {
      if (name === "ash-ui:component-event") listener = callback
    }
  }

  const target = {
    parentElement: null,
    getAttribute(name) {
      if (name === "phx-key") return "ash_ui:dispatch:tree.keydown"
      if (name === "phx-value-binding") return "tree.click"
      return null
    }
  }

  const hooks = createAshUiClientHooks()

  hooks.AshUiClient.mounted.call({
    el: root,
    pushEvent(_event, payload) {
      capturedPayload = payload
    }
  })

  listener({
    target,
    detail: {binding: "key", payload: {key: "Tab"}}
  })

  assert.deepEqual(capturedPayload, {binding: "tree.keydown", key: "Tab"})
})

test("component event helper can dispatch a named binding without a DOM event", () => {
  let capturedPayload

  const target = {
    parentElement: null,
    getAttribute(name) {
      if (name === "phx-click") return "ash_ui:dispatch:panel.toggle"
      return null
    }
  }

  const hooks = createAshUiClientHooks()
  const context = {
    el: {addEventListener() {}},
    pushEvent(_event, payload) {
      capturedPayload = payload
    }
  }

  hooks.AshUiClient.mounted.call(context)
  context.dispatchBlueprintComponentEvent(target, {path: "/files"}, "toggle")

  assert.deepEqual(capturedPayload, {binding: "panel.toggle", path: "/files"})
})

test("base hook dispatches matching same-origin external client commands", () => {
  let messageListener
  let capturedEvent
  let capturedPayload
  let stopped = false

  const action = {
    action: "refresh-tree",
    target: "root",
    using: "external_command",
    path: [],
    opts: {
      command: "refresh",
      source: "panel_gl",
      type: "panel:tree-command"
    }
  }

  const root = {
    addEventListener() {},
    getAttribute(name) {
      if (name === "data-ash-ui-client-actions") return JSON.stringify([action])
      return null
    },
    querySelectorAll() {
      return []
    }
  }

  const originalWindow = globalThis.window

  globalThis.window = {
    location: {origin: "http://localhost:4019"},
    addEventListener(name, listener, options) {
      if (name === "message") {
        messageListener = listener
        assert.equal(Boolean(options?.signal), true)
      }
    }
  }

  try {
    const hooks = createAshUiClientHooks()

    hooks.AshUiClient.mounted.call({
      el: root,
      pushEvent(event, payload) {
        capturedEvent = event
        capturedPayload = payload
      }
    })

    messageListener({
      origin: "http://localhost:4019",
      data: {
        source: "panel_gl",
        type: "panel:tree-command",
        command: "refresh",
        payload: {reason: "header"}
      },
      stopImmediatePropagation() {
        stopped = true
      }
    })

    assert.equal(capturedEvent, "ash_ui:dispatch")
    assert.deepEqual(capturedPayload, {
      action: "refresh-tree",
      reason: "header"
    })
    assert.equal(stopped, true)

    capturedPayload = null
    messageListener({
      origin: "http://evil.invalid",
      data: {source: "panel_gl", type: "panel:tree-command", command: "refresh"}
    })

    assert.equal(capturedPayload, null)
  } finally {
    globalThis.window = originalWindow
  }
})

test("base hook dispatches external commands from no-id action descendants", () => {
  let messageListener
  let capturedPayload

  const action = {
    action: "collapse-all",
    target: "root",
    using: "external_command",
    path: [],
    opts: {
      command: "collapse_all",
      source: "panel_gl",
      type: "panel:tree-command"
    }
  }

  const actionElement = {
    getAttribute(name) {
      if (name === "data-ash-ui-client-actions") return JSON.stringify([action])
      return null
    }
  }

  const hookRoot = {
    addEventListener() {},
    getAttribute(name) {
      if (name === "id") return "ash-ui-client-1"
      return null
    },
    querySelectorAll(selector) {
      if (selector === "[data-ash-ui-client-actions]") return [actionElement]
      return []
    }
  }

  const originalWindow = globalThis.window

  globalThis.window = {
    location: {origin: "http://localhost:4021"},
    addEventListener(name, listener) {
      if (name === "message") messageListener = listener
    }
  }

  try {
    const hooks = createAshUiClientHooks()

    hooks.AshUiClient.mounted.call({
      el: hookRoot,
      pushEvent(_event, payload) {
        capturedPayload = payload
      }
    })

    messageListener({
      origin: "http://localhost:4021",
      data: {source: "panel_gl", type: "panel:tree-command", command: "collapse_all"}
    })

    assert.deepEqual(capturedPayload, {
      action: "collapse-all"
    })
  } finally {
    globalThis.window = originalWindow
  }
})

test("base hook focuses a declared target when the focus target changes", () => {
  let focused = 0
  let focusOptions
  let capturedSelector

  const target = {
    ownerDocument: {activeElement: null},
    focus(options) {
      focused += 1
      focusOptions = options
    }
  }

  const root = {
    addEventListener() {},
    getAttribute(name) {
      if (name === "data-ash-ui-focus-target") return "explorer-filter"
      return null
    },
    matches() {
      return false
    },
    querySelector(selector) {
      capturedSelector = selector
      return target
    }
  }

  const originalWindow = globalThis.window
  const originalDocument = globalThis.document

  globalThis.window = {
    location: {origin: "http://localhost:4019"},
    addEventListener() {},
    CSS: {
      escape(value) {
        return value
      }
    }
  }
  globalThis.document = {activeElement: null}

  try {
    const hooks = createAshUiClientHooks()
    const context = {el: root}

    hooks.AshUiClient.mounted.call(context)
    hooks.AshUiClient.updated.call(context)

    assert.equal(focused, 1)
    assert.deepEqual(focusOptions, {preventScroll: true})
    assert.equal(
      capturedSelector,
      '[data-ash-ui-focus-key="explorer-filter"],[data-keybinding-target="explorer-filter"]'
    )
  } finally {
    globalThis.window = originalWindow
    globalThis.document = originalDocument
  }
})

test("built-in file upload action posts multipart data and redirects from response metadata", async () => {
  const action = {
    using: "file_upload",
    dom_event: "change",
    opts: {
      url: "/api/pdf_documents/upload",
      file_field: "pdf_file",
      title_field: "title",
      title_from_filename: true,
      status_selector: "#upload-status",
      control_selector: "#upload-label",
      redirect_path: "/",
      redirect_param: "document_id",
      response_id_path: ["data", "id"],
      preserve_params: ["ui_session_id"]
    }
  }

  const listeners = new Map()
  const status = {textContent: ""}
  const controlAttrs = {}
  const control = {
    setAttribute(name, value) {
      controlAttrs[name] = value
    }
  }

  const file = new Blob(["%PDF-1.7\n"], {type: "application/pdf"})
  Object.defineProperty(file, "name", {value: "invoice.pdf"})

  const input = {
    files: [file],
    value: "invoice.pdf",
    disabled: false,
    getAttribute(name) {
      if (name === "data-ash-ui-client-actions") return JSON.stringify([action])
      if (name === "id") return "pdf-upload-input"
      return null
    },
    addEventListener(name, listener, options) {
      listeners.set(name, {listener, options})
    }
  }

  const originalDocument = globalThis.document
  const originalWindow = globalThis.window
  const originalFetch = globalThis.fetch
  let capturedRequest
  let assignedUrl

  globalThis.document = {
    querySelector(selector) {
      if (selector === "meta[name='csrf-token']") {
        return {getAttribute: () => "csrf-token"}
      }

      if (selector === "#upload-status") return status
      if (selector === "#upload-label") return control

      return null
    }
  }

  globalThis.window = {
    location: {
      href: "http://localhost:4017/?ui_session_id=ui_1",
      assign(url) {
        assignedUrl = url
      }
    },
    CSS: {
      escape(value) {
        return value
      }
    }
  }

  globalThis.fetch = async (url, options) => {
    capturedRequest = {url, options}

    return new Response(JSON.stringify({data: {id: "doc_123"}}), {
      status: 200,
      headers: {"content-type": "application/json"}
    })
  }

  try {
    const hooks = createAshUiClientHooks()
    hooks.AshUiClient.mounted.call({el: input})

    assert.equal(typeof listeners.get("change")?.listener, "function")
    await listeners.get("change").listener({})

    assert.equal(capturedRequest.url, "/api/pdf_documents/upload")
    assert.equal(capturedRequest.options.method, "POST")
    assert.equal(capturedRequest.options.headers["x-csrf-token"], "csrf-token")
    assert.equal(capturedRequest.options.body.get("title"), "invoice")
    assert.equal(capturedRequest.options.body.has("pdf_file"), true)
    assert.equal(input.value, "")
    assert.equal(controlAttrs["aria-disabled"], "true")
    assert.equal(assignedUrl, "http://localhost:4017/?ui_session_id=ui_1&document_id=doc_123")
  } finally {
    globalThis.document = originalDocument
    globalThis.window = originalWindow
    globalThis.fetch = originalFetch
  }
})
