const DEFAULT_CLOCK = {
  setTimeout(callback, delay) {
    return globalThis.setTimeout(callback, delay)
  },
  clearTimeout(timer) {
    globalThis.clearTimeout(timer)
  }
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function normalizedName(value) {
  const name = String(value || "")
  return name === "" ? null : name
}

function rootName(root) {
  return normalizedName(root?.getAttribute?.("data-ash-ui-island"))
}

function decodeAttribute(root, attribute, fallback, reportError) {
  const encoded = root?.getAttribute?.(attribute) || "{}"

  try {
    const decoded = JSON.parse(encoded)
    return isObject(decoded) ? decoded : fallback
  } catch (error) {
    reportError(error, {phase: "decode", attribute, root})
    return null
  }
}

function debounceDelay(option, event) {
  const configured = isObject(option) ? option[event] : option
  const delay = Number(configured ?? 0)

  if (!Number.isFinite(delay)) return 0
  return Math.max(0, Math.min(100, delay))
}

function defaultError(error) {
  globalThis.console?.error?.("AshUi island runtime error", error)
}

function defaultTelemetry(event, detail) {
  globalThis.performance?.mark?.(`ash-ui:island:${event}`)

  const root = detail?.root
  const CustomEventClass = globalThis.CustomEvent

  if (root?.dispatchEvent && typeof CustomEventClass === "function") {
    root.dispatchEvent(
      new CustomEventClass("ash-ui:island-telemetry", {
        detail: {event, ...detail}
      })
    )
  }
}

export function createIslandRuntime({
  binding,
  host,
  clock = DEFAULT_CLOCK,
  lifecycleTarget = globalThis.window,
  telemetry = defaultTelemetry,
  onError = defaultError
} = {}) {
  if (!binding || typeof binding.observe !== "function" || typeof binding.send !== "function") {
    throw new Error("AshUi island runtime requires an observe/send binding")
  }

  if (typeof clock?.setTimeout !== "function" || typeof clock?.clearTimeout !== "function") {
    throw new Error("AshUi island runtime clock requires setTimeout and clearTimeout")
  }

  const islandHost = hostAffordances(host)

  const definitions = new Map()
  const roots = new WeakMap()
  const activeRoots = new Set()
  const rootsByName = new Map()
  let unloadListenersInstalled = false

  function reportError(error, detail = {}) {
    try {
      onError(error, detail)
    } catch (funnelError) {
      defaultError(funnelError)
    }

    telemetry("error", {...detail, error})
  }

  function nameStates(name) {
    let states = rootsByName.get(name)

    if (!states) {
      states = new Set()
      rootsByName.set(name, states)
    }

    return states
  }

  function meta(state, initial = false) {
    return {name: state.name, root: state.root, initial}
  }

  function emitDropped(state, event, payload, reason, pendingWaiters = []) {
    const detail = {name: state.name, root: state.root, event, payload, reason}
    const observer = state.definition?.onEmitDropped

    if (observer === "telemetry") {
      telemetry("emit-dropped", detail)
    } else if (typeof observer === "function") {
      try {
        observer(detail)
      } catch (error) {
        reportError(error, {...detail, phase: "emit-dropped"})
      }
    }

    const result = {dropped: true, reason}
    for (const waiter of pendingWaiters) waiter.resolve(result)
    return result
  }

  function emissionDropReason(state) {
    if (state.unloading) return "unloading"
    if (state.status === "torn-down") return "torn-down"

    const policy = state.definition?.emitWhile || "live"

    if (state.status === "suspended" && policy === "live") return "suspended"
    if (state.applying && policy !== "always") return "applying"
    if (state.status !== "live" && state.status !== "suspended") return state.status

    return null
  }

  function bindings(state) {
    return decodeAttribute(
      state.root,
      "data-ash-ui-island-events",
      {},
      (error, detail) => reportError(error, {...detail, name: state.name})
    )
  }

  async function sendNow(state, event, payload) {
    const reason = emissionDropReason(state)
    if (reason) return emitDropped(state, event, payload, reason)

    const bindingKey = bindings(state)?.[event]

    if (!bindingKey) {
      throw new Error(`AshUi island "${state.name}" has no bound event "${event}"`)
    }

    telemetry("emit", {name: state.name, root: state.root, event})
    return binding.send(state.root, bindingKey, payload)
  }

  function settlePending(state, event) {
    const pending = state.pending.get(event)
    if (!pending) return

    state.pending.delete(event)
    if (pending.timer !== null) clock.clearTimeout(pending.timer)

    Promise.resolve()
      .then(() => sendNow(state, event, pending.payload))
      .then(
        result => pending.waiters.forEach(waiter => waiter.resolve(result)),
        error => {
          reportError(error, {name: state.name, root: state.root, event, phase: "emit"})
          pending.waiters.forEach(waiter => waiter.reject(error))
        }
      )
  }

  // Settle a pending emission NOW, on the caller's own stack. `settlePending` hands the
  // send to a microtask, which is one turn too late when the adapter is racing an echo
  // the DOM/runtime it drives is about to produce synchronously.
  function flushPending(state, event) {
    const pending = state.pending.get(event)
    if (!pending) return

    state.pending.delete(event)
    if (pending.timer !== null) clock.clearTimeout(pending.timer)

    try {
      Promise.resolve(sendNow(state, event, pending.payload)).then(
        result => pending.waiters.forEach(waiter => waiter.resolve(result)),
        error => {
          reportError(error, {name: state.name, root: state.root, event, phase: "emit"})
          pending.waiters.forEach(waiter => waiter.reject(error))
        }
      )
    } catch (error) {
      reportError(error, {name: state.name, root: state.root, event, phase: "emit"})
      pending.waiters.forEach(waiter => waiter.reject(error))
    }
  }

  function schedulePending(state, event) {
    const pending = state.pending.get(event)
    if (!pending || state.holds > 0 || pending.timer !== null) return

    const delay = debounceDelay(state.definition?.debounce, event)

    if (delay === 0) {
      settlePending(state, event)
    } else {
      pending.timer = clock.setTimeout(() => {
        pending.timer = null
        settlePending(state, event)
      }, delay)
    }
  }

  function clearPending(state, reason) {
    for (const [event, pending] of state.pending) {
      if (pending.timer !== null) clock.clearTimeout(pending.timer)
      emitDropped(state, event, pending.payload, reason, pending.waiters)
    }

    state.pending.clear()
  }

  function emit(state, event, payload = {}) {
    const normalizedEvent = String(event || "")
    const eventPayload = isObject(payload) ? payload : {}
    const reason = emissionDropReason(state)

    if (reason) return Promise.resolve(emitDropped(state, normalizedEvent, eventPayload, reason))

    const delay = debounceDelay(state.definition?.debounce, normalizedEvent)
    if (state.holds === 0 && delay === 0) {
      try {
        return Promise.resolve(sendNow(state, normalizedEvent, eventPayload)).catch(error => {
          reportError(error, {
            name: state.name,
            root: state.root,
            event: normalizedEvent,
            phase: "emit"
          })
          throw error
        })
      } catch (error) {
        reportError(error, {
          name: state.name,
          root: state.root,
          event: normalizedEvent,
          phase: "emit"
        })
        return Promise.reject(error)
      }
    }

    return new Promise((resolve, reject) => {
      const pending = state.pending.get(normalizedEvent) || {
        payload: eventPayload,
        timer: null,
        waiters: []
      }

      pending.payload = eventPayload
      pending.waiters.push({resolve, reject})
      state.pending.set(normalizedEvent, pending)
      schedulePending(state, normalizedEvent)
    })
  }

  function context(state) {
    const ctx = {
      root: state.root,
      emit: (event, payload) => emit(state, event, payload),
      hold() {
        state.holds += 1
      },
      release() {
        state.holds = Math.max(0, state.holds - 1)
        if (state.holds === 0) {
          for (const event of state.pending.keys()) schedulePending(state, event)
        }
      },
      discard() {
        state.holds = Math.max(0, state.holds - 1)
        clearPending(state, "discarded")
      },
      // Send what is pending immediately, bypassing the rest of its debounce window: a
      // discrete change the adapter must get ahead of, not a storm to coalesce.
      flush(event) {
        const events = event === undefined ? [...state.pending.keys()] : [String(event)]
        for (const name of events) flushPending(state, name)
      },
      // Drop what is pending WITHOUT touching the gating: for a pending emission the
      // adapter knows is obsolete (its subject was replaced), while a hold it did not
      // take must survive.
      clearPending(reason = "cleared") {
        clearPending(state, String(reason))
      },
      telemetry(event, detail = {}) {
        telemetry(event, {name: state.name, root: state.root, ...detail})
      },
      onError(error, detail = {}) {
        reportError(error, {name: state.name, root: state.root, ...detail})
      },
      // What the page's host lets an island ask of it (`hostAffordances/1`); undefined when the
      // adapter that mounted the page offers nothing.
      host: islandHost
    }

    Object.defineProperty(ctx, "suspended", {
      enumerable: true,
      get() {
        return state.status === "suspended"
      }
    })

    return Object.freeze(ctx)
  }

  function thenMaybe(value, next) {
    return value && typeof value.then === "function" ? value.then(next) : next(value)
  }

  function enqueue(state, phase, task) {
    const run = () => {
      state.applying = phase === "create" || phase === "props"

      try {
        const result = task()

        if (result && typeof result.then === "function") {
          return result.finally(() => {
            state.applying = false
          })
        }

        state.applying = false
        return result
      } catch (error) {
        state.applying = false
        throw error
      }
    }

    const idle = state.queued === 0
    state.queued += 1
    let result

    try {
      result = idle ? run() : state.queue.then(run)
    } catch (error) {
      state.queued -= 1
      reportError(error, {name: state.name, root: state.root, phase})
      state.queue = Promise.resolve()
      return state.queue
    }

    if (idle && !(result && typeof result.then === "function")) {
      state.queued -= 1
      state.queue = Promise.resolve(result)
    } else {
      state.queue = Promise.resolve(result)
        .catch(error => {
          reportError(error, {name: state.name, root: state.root, phase})
        })
        .finally(() => {
          state.queued -= 1
        })
    }

    return state.queue
  }

  function deliverProps(state, initial) {
    if (!state.instance || state.props === null) return state.queue
    const props = state.props

    return enqueue(state, "props", () => {
      telemetry("props", {name: state.name, root: state.root, initial})
      return state.instance?.props?.(props, meta(state, initial))
    })
  }

  function activate(state, definition, initial = true) {
    if (!definition || state.status === "torn-down") return state.queue
    if (state.definition === definition && state.instance) return deliverProps(state, initial)

    state.definition = definition

    return enqueue(state, "create", () => {
      const destroy = state.instance?.destroy?.()

      return thenMaybe(destroy, () => {
        const created = definition.create(state.root, context(state))

        return thenMaybe(created, instance => {
          state.instance = instance || {}
          state.status = state.status === "suspended" ? "suspended" : "live"

          if (state.props !== null) {
            telemetry("props", {name: state.name, root: state.root, initial})
            return state.instance?.props?.(state.props, meta(state, initial))
          }

          return undefined
        })
      })
    })
  }

  function installUnloadListeners() {
    if (
      unloadListenersInstalled ||
      typeof lifecycleTarget?.addEventListener !== "function"
    ) {
      return
    }

    lifecycleTarget.addEventListener("pagehide", unload)
    lifecycleTarget.addEventListener("beforeunload", unload)
    unloadListenersInstalled = true
  }

  function removeUnloadListeners() {
    if (
      !unloadListenersInstalled ||
      activeRoots.size > 0 ||
      typeof lifecycleTarget?.removeEventListener !== "function"
    ) {
      return
    }

    lifecycleTarget.removeEventListener("pagehide", unload)
    lifecycleTarget.removeEventListener("beforeunload", unload)
    unloadListenersInstalled = false
  }

  function attach(root) {
    if (!root || roots.has(root)) {
      if (root) sync(root)
      return roots.get(root)?.queue
    }

    const name = rootName(root)
    if (!name) return undefined

    const encoded = root.getAttribute?.("data-ash-ui-island-props") || "{}"
    const state = {
      root,
      name,
      status: "discovered",
      unloading: false,
      applying: false,
      definition: null,
      instance: null,
      encoded,
      props: decodeAttribute(root, "data-ash-ui-island-props", {}, (error, detail) =>
        reportError(error, {...detail, name})
      ),
      holds: 0,
      pending: new Map(),
      queue: Promise.resolve(),
      queued: 0,
      teardown: null
    }

    roots.set(root, state)
    activeRoots.add(root)
    nameStates(name).add(state)
    installUnloadListeners()
    telemetry("discovered", {name, root})

    const definition = definitions.get(name)
    if (definition) activate(state, definition)
    return state.queue
  }

  function sync(root) {
    const state = roots.get(root)
    if (!state) return attach(root)
    if (state.status === "torn-down") return state.teardown

    const name = rootName(root)

    if (name !== state.name) {
      detach(root, "name-changed")
      roots.delete(root)
      if (name) return attach(root)
      return state.teardown
    }

    const encoded = root.getAttribute?.("data-ash-ui-island-props") || "{}"
    if (encoded === state.encoded) return state.queue

    // This encoded-string gate intentionally precedes JSON.parse. It is the
    // unchanged-props fast path for LiveView's broader dataset update signal.
    state.encoded = encoded
    const props = decodeAttribute(root, "data-ash-ui-island-props", {}, (error, detail) =>
      reportError(error, {...detail, name: state.name})
    )

    if (props === null) return state.queue
    state.props = props
    return deliverProps(state, false)
  }

  function suspend(root) {
    const state = roots.get(root)
    if (!state || state.status === "torn-down" || state.unloading) return state?.queue
    if (state.status === "suspended") return state.queue

    state.status = "suspended"
    telemetry("suspended", {name: state.name, root})
    return enqueue(state, "suspend", () => state.instance?.suspend?.())
  }

  function resume(root) {
    const state = roots.get(root)
    if (!state || state.status === "torn-down" || state.unloading) return state?.queue
    if (state.status !== "suspended") return state.queue

    state.status = state.definition ? "live" : "discovered"
    telemetry("resumed", {name: state.name, root})
    return enqueue(state, "resume", () => state.instance?.resume?.())
  }

  function detach(root, reason = "terminal") {
    const state = roots.get(root)
    if (!state) return Promise.resolve()
    if (state.status === "torn-down") return state.teardown

    state.unloading = reason === "unloading" || state.unloading
    state.status = "torn-down"
    clearPending(state, state.unloading ? "unloading" : "torn-down")
    rootsByName.get(state.name)?.delete(state)
    if (rootsByName.get(state.name)?.size === 0) rootsByName.delete(state.name)
    activeRoots.delete(root)
    removeUnloadListeners()
    telemetry("torn-down", {name: state.name, root, reason})

    state.teardown = enqueue(state, "destroy", () => {
      return thenMaybe(state.instance?.destroy?.(), () => {
        state.instance = null
        state.definition = null
      })
    })

    return state.teardown
  }

  function unload() {
    for (const root of [...activeRoots]) detach(root, "unloading")
  }

  binding.observe({
    onAttach: attach,
    onSync: sync,
    onDetach: detach,
    onSuspend: suspend,
    onResume: resume
  })

  function define(name, definition) {
    const normalized = normalizedName(name)

    if (!normalized) {
      throw new Error("AshUi.island.define requires a non-empty island name")
    }

    if (!isObject(definition) || typeof definition.create !== "function") {
      throw new Error(
        `AshUi.island.define("${normalized}") requires a create(root, ctx) function`
      )
    }

    const emitWhile = definition.emitWhile || "live"
    if (!["live", "suspended", "always"].includes(emitWhile)) {
      throw new Error(
        `AshUi.island.define("${normalized}") emitWhile must be live, suspended, or always`
      )
    }

    const normalizedDefinition = {...definition, emitWhile}
    definitions.set(normalized, normalizedDefinition)

    for (const state of rootsByName.get(normalized) || []) {
      activate(state, normalizedDefinition, true)
    }

    return definition
  }

  function emitByName(name, event, payload = {}) {
    const normalized = normalizedName(name)
    const [state] = rootsByName.get(normalized) || []

    if (!state) {
      throw new Error(`AshUi island "${normalized || ""}" is not mounted`)
    }

    return emit(state, event, payload)
  }

  return Object.freeze({define, emitByName})
}

/**
 * THE HOST AFFORDANCES an island may use: what the adapter mounting the page offers, as the MCP
 * Apps bridge names it — `downloadFile` (`ui/download-file`), `sendMessage`
 * (`ui/message`) and `updateModelContext` (`ui/update-model-context`), each taking that request's
 * params and answering its result, and `capabilities`, the host's own capability flags for them.
 *
 * Only these members cross: the island gets a frozen copy, never the adapter. Each is an explicit
 * act of the island's own code (a user's click on an island control); nothing here runs on its
 * own, and the page's rendered text never reaches the host through it.
 */
const HOST_METHODS = ["downloadFile", "sendMessage", "updateModelContext"]

export function hostAffordances(host) {
  if (host === undefined || host === null) return undefined
  if (typeof host !== "object") {
    throw new Error("AshUi island runtime host must be an object of affordances")
  }
  const declared = host.capabilities && typeof host.capabilities === "object" ? host.capabilities : {}
  const affordances = {}
  for (const name of HOST_METHODS) {
    if (host[name] === undefined) continue
    if (typeof host[name] !== "function") {
      throw new Error(`AshUi island runtime host.${name} must be a function`)
    }
    // The capability gate binds: a method the host declares unavailable is not offered at all.
    if (declared[name] === false) continue
    affordances[name] = (params) => Promise.resolve().then(() => host[name](params))
  }
  // `capabilities[name]` is true exactly when the island can call `name`.
  affordances.capabilities = Object.freeze(Object.fromEntries(HOST_METHODS.map((name) =>
    [name, affordances[name] !== undefined])))
  return Object.freeze(affordances)
}
