import {
  AshUiClient,
  ashUiEventFormPayload,
  ashUiFormPayload,
  attachAshUiRuntime,
  createAshUiClientHooks,
  emitIsland,
  island,
  installAshUiDomEventBridge,
  registerIsland
} from "./client.js"

const registeredRuntimes = []
let bootedLiveSocket = null
const patchTransportOnlyKeys = new Set(["e", "r", "t"])

function browserWindow() {
  return globalThis.window
}

function browserDocument() {
  return browserWindow()?.document || globalThis.document
}

function csrfToken() {
  return browserDocument()
    ?.querySelector?.('meta[name="csrf-token"]')
    ?.getAttribute?.("content")
}

function socketParams(params = {}, token = csrfToken()) {
  if (!token) return {...params}

  return {_csrf_token: token, ...params}
}

function modifierMetadata(event) {
  return {
    alt: !!event.altKey,
    ctrl: !!event.ctrlKey,
    meta: !!event.metaKey,
    shift: !!event.shiftKey
  }
}

function selectedOptions(element) {
  return Array.from(element?.selectedOptions || []).map(option => option.value)
}

function inputMetadata(event) {
  const target = event.target

  return {
    value: target?.value,
    checked: !!target?.checked,
    selectedOptions: selectedOptions(target)
  }
}

function ashUiEventMetadata() {
  return {
    click: (event, target) => ({
      ...ashUiEventFormPayload(event, target),
      button: event.button,
      buttons: event.buttons,
      ...modifierMetadata(event)
    }),
    keydown: (event, target) => ({
      ...ashUiEventFormPayload(event, target),
      key: event.key,
      ...modifierMetadata(event)
    }),
    keyup: (event, target) => ({
      ...ashUiEventFormPayload(event, target),
      key: event.key,
      ...modifierMetadata(event)
    }),
    input: inputMetadata,
    change: event => ({
      ...inputMetadata(event),
      form: ashUiFormPayload(event.target?.form || event.target)
    }),
    submit: event => ({form: ashUiFormPayload(event.target)}),
    contextmenu: event => ({
      clientX: event.clientX,
      clientY: event.clientY,
      pageX: event.pageX,
      pageY: event.pageY,
      screenX: event.screenX,
      screenY: event.screenY,
      button: event.button,
      buttons: event.buttons,
      ...modifierMetadata(event)
    })
  }
}

function patchMessage(message) {
  const diff =
    message?.event === "diff"
      ? message.payload
      : message?.event === "phx_reply"
        ? message?.payload?.response?.diff
        : null

  if (!diff) return false
  if (typeof diff !== "object") return true

  // Rendered.extract removes these transport-only keys before View.update.
  // A reply/event/title-only payload therefore never starts a DOM patch.
  // LiveView does not invoke its DOM patch callbacks for an empty diff. Do not
  // enqueue one or it would be paired with the next patch's apply callbacks.
  return Object.keys(diff).some(key => !patchTransportOnlyKeys.has(key))
}

export function createAshUiPatchInstrumentation({
  performance = browserWindow()?.performance || globalThis.performance,
  requestAnimationFrame = browserWindow()?.requestAnimationFrame,
  scheduleTask = callback => globalThis.setTimeout(callback, 0)
} = {}) {
  const pending = []
  let sequence = 0
  let active = null
  const nextFrame = requestAnimationFrame || (callback => setTimeout(callback, 0))

  const mark = (name, detail) => {
    if (typeof performance?.mark !== "function") return

    try {
      return performance.mark(name, {detail})
    } catch (_unsupportedOptions) {
      return performance.mark(name)
    }
  }

  const timingPoint = (name, detail) => mark(name, detail)?.startTime ?? name

  const measure = (name, start, end, detail) => {
    if (typeof performance?.measure !== "function") return

    try {
      performance.measure(name, {start, end, detail})
    } catch (_unsupportedOptions) {
      performance.measure(name, start, end)
    }
  }

  return {
    received(message) {
      if (!patchMessage(message)) return

      const id = ++sequence
      const receive = timingPoint("ash-ui:patch-receive", {id})
      pending.push({id, receive})
    },

    applyStarted(_container) {
      const patch = pending.shift()
      if (!patch) return

      patch.applyStart = timingPoint("ash-ui:patch-apply-start", {id: patch.id})
      active = patch
      measure("ash-ui:patch-receive-to-apply", patch.receive, patch.applyStart, {
        id: patch.id
      })
    },

    applyEnded(_container) {
      const patch = active
      if (!patch) return

      active = null
      patch.applyEnd = timingPoint("ash-ui:patch-apply-end", {id: patch.id})
      measure("ash-ui:patch-apply", patch.applyStart, patch.applyEnd, {id: patch.id})

      nextFrame(() => {
        const frame = timingPoint("ash-ui:patch-frame", {id: patch.id})
        measure("ash-ui:patch-apply-to-frame", patch.applyEnd, frame, {
          id: patch.id
        })

        // rAF runs before style/layout/paint. A task posted from that callback
        // runs after Chromium has presented the frame; a second rAF would add
        // an unrelated refresh interval to every patch measurement.
        scheduleTask(() => {
          const paint = timingPoint("ash-ui:patch-paint", {id: patch.id})
          measure("ash-ui:patch-apply-to-paint", patch.applyEnd, paint, {
            id: patch.id
          })
          measure("ash-ui:patch-receive-to-paint", patch.receive, paint, {id: patch.id})
          measure("ash-ui:patch-frame-to-paint", frame, paint, {id: patch.id})
        })
      })
    }
  }
}

export function registerRuntime(runtime) {
  if (!runtime) return runtime

  registeredRuntimes.push(runtime)

  // A runtime arriving after boot (async module loaders finish their dynamic
  // import after DOMContentLoaded) composes into the live hook set and
  // retro-mounts onto elements already in the DOM — registration order must
  // never decide whether a pane's controls attach.
  if (bootedLiveSocket) attachAshUiRuntime(runtime)

  return runtime
}

export function runtimes() {
  return registeredRuntimes.slice()
}

export function bootAshUiLiveSocket(options = {}) {
  if (bootedLiveSocket) return bootedLiveSocket

  const win = browserWindow()
  const PhoenixSocket = options.Socket || win?.Phoenix?.Socket
  const LiveSocket = options.LiveSocket || win?.LiveView?.LiveSocket

  if (!win || !PhoenixSocket || !LiveSocket) return null

  const patchInstrumentation = createAshUiPatchInstrumentation()
  const configuredDom = options.dom || {}

  const liveSocket = new LiveSocket(options.path || "/live", PhoenixSocket, {
    hooks: createAshUiClientHooks({
      runtimes: runtimes(),
      hooks: options.hooks || [],
      baseHooks: options.baseHooks || {},
      extraHooks: options.extraHooks || {}
    }),
    params: socketParams(options.params, options.csrfToken ?? csrfToken()),
    metadata: {...ashUiEventMetadata(), ...(options.metadata || {})},
    dom: {
      ...configuredDom,
      onPatchStart(container) {
        patchInstrumentation.applyStarted(container)
        configuredDom.onPatchStart?.(container)
      },
      onPatchEnd(container) {
        patchInstrumentation.applyEnded(container)
        configuredDom.onPatchEnd?.(container)
      }
    }
  })

  const phoenixSocket = liveSocket.getSocket?.()

  if (typeof phoenixSocket?.decode === "function") {
    const decode = phoenixSocket.decode.bind(phoenixSocket)

    // Phoenix Socket.onConnMessage routes a decoded message through its
    // channels before invoking Socket.onMessage callbacks. Observe inside the
    // decoder callback instead, immediately before Phoenix receives the value,
    // so "patch-receive" cannot be paired with a later patch.
    phoenixSocket.decode = (rawMessage, callback) =>
      decode(rawMessage, message => {
        patchInstrumentation.received(message)
        callback(message)
      })
  }

  installAshUiDomEventBridge(liveSocket)
  // LiveView 1.1 enables verbose diff logging automatically on localhost.
  // Serving applications use localhost in normal operation, so make the
  // production boot path explicitly quiet before connect() applies that default.
  liveSocket.disableDebug?.()
  liveSocket.connect()
  win.liveSocket = liveSocket
  bootedLiveSocket = liveSocket

  return liveSocket
}

function onDomReady(callback) {
  const doc = browserDocument()

  if (!doc?.addEventListener || doc.readyState === "complete") {
    const enqueue = globalThis.queueMicrotask || (fn => setTimeout(fn, 0))
    enqueue(callback)
    return
  }

  // Deferred module bundles that register AshUi runtimes execute while
  // readyState is "interactive", BEFORE DOMContentLoaded. Booting on a timer
  // in that window races ahead of their registerRuntime calls and composes the
  // LiveSocket hooks without module client drivers. Wait for DOMContentLoaded.
  // A bundle injected after that event may still see "interactive" until load;
  // Navigation Timing distinguishes that case and preserves late boot.
  let ran = false

  const run = () => {
    if (ran) return
    ran = true
    callback()
  }

  doc.addEventListener("DOMContentLoaded", run, {once: true})

  const navigation =
    (browserWindow()?.performance || globalThis.performance)
      ?.getEntriesByType?.("navigation")
      ?.[0]

  if (doc.readyState === "interactive" && Number(navigation?.domContentLoadedEventEnd) > 0) {
    const enqueue = globalThis.queueMicrotask || (fn => setTimeout(fn, 0))
    enqueue(run)
  }
}

onDomReady(() => bootAshUiLiveSocket())

export {
  AshUiClient,
  createAshUiClientHooks,
  emitIsland,
  island,
  installAshUiDomEventBridge,
  registerIsland
}
