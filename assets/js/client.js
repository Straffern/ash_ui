import {createIslandRuntime} from "./island.js"
import {createPhoenixIslandBinding} from "./island_phoenix.js"
import {browserIslandHost} from "./island_host.js"

const LIFECYCLE_METHODS = [
  "mounted",
  "beforeUpdate",
  "updated",
  "destroyed",
  "disconnected",
  "reconnected"
]

function isObject(value) {
  return value !== null && typeof value === "object"
}

const dispatchFormPayloads = new WeakMap()
const inputPushStates = new WeakMap()
const backpressuredViews = new WeakSet()
const phoenixIslandBinding = createPhoenixIslandBinding()
const phoenixIslandRuntime = createIslandRuntime({binding: phoenixIslandBinding,
  host: typeof document === "undefined" ? undefined : browserIslandHost(document)})
export const island = Object.freeze({define: phoenixIslandRuntime.define})

export function registerIsland(name, adapter) {
  const normalizedName = String(name || "")

  if (!normalizedName) {
    throw new Error("AshUi.registerIsland requires a non-empty island name")
  }

  if (!isObject(adapter)) {
    throw new Error(`AshUi.registerIsland("${normalizedName}") requires an adapter object`)
  }

  phoenixIslandRuntime.define(normalizedName, {
    create(_root, _ctx) {
      return {
        props(props, meta) {
          return adapter.onProps?.(props, meta)
        },
        suspend() {
          return adapter.onDisconnected?.({name: normalizedName, root: _root, initial: false})
        },
        resume() {
          return adapter.onReconnected?.({name: normalizedName, root: _root, initial: false})
        },
        destroy() {
          return adapter.onDestroy?.({name: normalizedName, root: _root, initial: false})
        }
      }
    }
  })

  return adapter
}

export function emitIsland(name, event, payload = {}) {
  return phoenixIslandRuntime.emitByName(name, event, payload)
}

export function ashUiFormPayload(form) {
  if (!form || typeof FormData === "undefined") return {}

  const payload = {}

  for (const [key, value] of new FormData(form).entries()) {
    if (Object.prototype.hasOwnProperty.call(payload, key)) {
      payload[key] = Array.isArray(payload[key]) ? [...payload[key], value] : [payload[key], value]
    } else {
      payload[key] = value
    }
  }

  return payload
}

function enclosingForm(target) {
  if (!target) return null
  if (target.tagName === "FORM") return target

  return target.form || target.closest?.("form") || null
}

function captureEventFormPayload(event, target) {
  const payload = ashUiFormPayload(enclosingForm(target || event?.target))

  if (event && (typeof event === "object" || typeof event === "function")) {
    dispatchFormPayloads.set(event, payload)
  }

  return payload
}

export function ashUiEventFormPayload(event, target) {
  const captured = event && dispatchFormPayloads.get(event)
  return captured === undefined
    ? ashUiFormPayload(enclosingForm(target || event?.target))
    : captured
}

function clientActionData(element) {
  const encoded = element?.getAttribute?.("data-ash-ui-client-actions")
  if (!encoded) return []

  try {
    const actions = JSON.parse(encoded)
    return Array.isArray(actions) ? actions : []
  } catch (_error) {
    return []
  }
}

function cssEscape(value) {
  const stringValue = String(value || "")
  const browserWindow = globalThis.window

  if (browserWindow?.CSS?.escape) return browserWindow.CSS.escape(stringValue)

  return stringValue.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
}

const COMPONENT_EVENT_NAME = "ash-ui:component-event"
const SHIMMED_DOM_EVENTS = [
  "click",
  "contextmenu",
  "keydown",
  "keyup",
  "input",
  "change",
  "submit",
  "beforeunload",
  "visibilitychange"
]

function bindingAttributeNames(name) {
  if (!name) return ["phx-value-binding", "data-ash-ui-binding"]

  return [
    `phx-${name}`,
    `phx-value-binding-${name}`,
    `data-ash-ui-binding-${name}`,
    "phx-value-binding",
    "data-ash-ui-binding"
  ]
}

function blueprintBinding(element, name = null) {
  let current = element
  const attrs = bindingAttributeNames(name)

  while (current) {
    for (const attr of attrs) {
      const value = current?.getAttribute?.(attr)
      if (!value) continue

      if (!attr.startsWith("phx-value-") && attr.startsWith("phx-")) {
        const prefix = "ash_ui:dispatch:"
        if (value.startsWith(prefix)) return value.slice(prefix.length)
      } else {
        return value
      }
    }

    // Phoenix omits the duplicated lookup attributes on one-event elements.
    // If a component's semantic binding name differs from the DOM event name,
    // that one native event remains unambiguous. Multi-event elements keep the
    // legacy generic lookup, which is checked above before this fallback.
    for (const eventName of SHIMMED_DOM_EVENTS) {
      const value = current?.getAttribute?.(`phx-${eventName}`)
      const prefix = "ash_ui:dispatch:"
      if (value?.startsWith?.(prefix)) return value.slice(prefix.length)
    }

    current = current?.parentElement || null
  }

  return null
}

function pushBlueprintComponentEvent(hook, element, payload = {}, bindingName = null) {
  const binding = blueprintBinding(element, bindingName)

  if (!binding || typeof hook?.pushEvent !== "function") return false

  hook.pushEvent("ash_ui:dispatch", {binding, ...payload})
  return true
}

function dispatchBlueprintComponentEvent(hook, event) {
  const detail = event?.detail || {}
  const bindingName = detail.binding || detail.bindingName || detail.name || null
  const payload = detail.payload || {}

  if (!pushBlueprintComponentEvent(hook, event?.target, payload, bindingName)) return

  event.preventDefault?.()
  event.stopPropagation?.()
}

function installBlueprintComponentEventDispatcher(hook) {
  hook.dispatchBlueprintComponentEvent = (element, payload = {}, bindingName = null) =>
    pushBlueprintComponentEvent(hook, element, payload, bindingName)
}

function installBlueprintClientActionDispatcher(hook) {
  if (!hook || typeof hook.pushEvent !== "function") return

  hook.dispatchBlueprintClientAction = (clientAction, payload = {}) => {
    if (!clientAction?.action) return

    return hook.pushEvent("ash_ui:dispatch", {
      action: clientAction.action,
      ...payload
    })
  }
}

function sameOriginMessage(event) {
  return event?.origin && event.origin === globalThis.window?.location?.origin
}

function externalCommandPayload(event) {
  const data = event?.data
  if (!sameOriginMessage(event) || !isObject(data)) return null

  const command = data.command
  if (typeof command !== "string" || command === "") return null

  return {
    command,
    type: typeof data.type === "string" ? data.type : null,
    source: typeof data.source === "string" ? data.source : null,
    payload: isObject(data.payload) ? data.payload : {}
  }
}

function externalCommandActionMatches(action, message) {
  const opts = action?.opts || {}

  if (action?.using !== "external_command") return false
  if (opts.command !== message.command) return false
  if (opts.type && opts.type !== message.type) return false
  if (opts.source && opts.source !== message.source) return false

  return true
}

function externalCommandActionTargets(root) {
  const targets = []

  if (root?.getAttribute?.("data-ash-ui-client-actions")) targets.push(root)

  if (typeof root?.querySelectorAll === "function") {
    targets.push(...root.querySelectorAll("[data-ash-ui-client-actions]"))
  }

  return targets
}

function dispatchBlueprintExternalCommand(hook, event) {
  const message = externalCommandPayload(event)
  if (!message || typeof hook?.dispatchBlueprintClientAction !== "function") return false

  for (const target of externalCommandActionTargets(hook?.el)) {
    const action = clientActionData(target).find((candidate) =>
      externalCommandActionMatches(candidate, message)
    )

    if (!action) continue

    hook.dispatchBlueprintClientAction(action, message.payload)
    event.stopImmediatePropagation?.()
    event.stopPropagation?.()
    return true
  }

  return false
}

function bindExternalCommandDispatch(hook) {
  const root = hook?.el
  const browserWindow = globalThis.window
  if (!root || typeof browserWindow?.addEventListener !== "function") return

  hook.__ashUiExternalCommandAbortController?.abort?.()

  const abortController = new AbortController()
  hook.__ashUiExternalCommandAbortController = abortController

  browserWindow.addEventListener(
    "message",
    event => dispatchBlueprintExternalCommand(hook, event),
    {signal: abortController.signal}
  )
}

function bindComponentEventDispatch(hook) {
  const root = hook?.el
  if (!root?.addEventListener) return

  hook.__ashUiComponentEventAbortController?.abort?.()

  const abortController = new AbortController()
  hook.__ashUiComponentEventAbortController = abortController

  root.addEventListener(
    COMPONENT_EVENT_NAME,
    event => dispatchBlueprintComponentEvent(hook, event),
    {signal: abortController.signal}
  )
}

function focusBlueprintTarget(hook) {
  const root = hook?.el
  const targetName = root?.getAttribute?.("data-ash-ui-focus-target")
  if (!targetName || hook.__ashUiLastFocusedTarget === targetName) return

  hook.__ashUiLastFocusedTarget = targetName

  const selector = [
    `[data-ash-ui-focus-key="${cssEscape(targetName)}"]`,
    `[data-keybinding-target="${cssEscape(targetName)}"]`
  ].join(",")

  const target =
    root?.matches?.(selector) ? root : root?.querySelector?.(selector)

  if (!target || typeof target.focus !== "function") return

  const activeElement = target.ownerDocument?.activeElement || globalThis.document?.activeElement
  if (activeElement === target) return

  target.focus({preventScroll: true})
}

function controlledValueVersion(element) {
  return element?.__ashUiControlledValueVersion || 0
}

function advanceControlledValueVersion(element) {
  element.__ashUiControlledValueVersion = controlledValueVersion(element) + 1
}

function recordControlledValueEdit(element) {
  if (!["INPUT", "TEXTAREA", "SELECT"].includes(element?.tagName)) return
  if (element.type === "file") return

  advanceControlledValueVersion(element)
}

function recordControlledValueDispatch(element) {
  if (!["INPUT", "TEXTAREA", "SELECT"].includes(element?.tagName)) return
  if (element.type === "file" || element.getAttribute?.("value") === null) return

  element.__ashUiDispatchedValueVersion = controlledValueVersion(element)
  element.__ashUiDispatchedValue = element.value
}

function controlledDispatchElements(target) {
  const form = enclosingForm(target)

  if (form) {
    return Array.from(
      form.querySelectorAll?.("input[value],textarea[value],select[value]") || []
    )
  }

  return [target]
}

function recordControlledDispatch(target) {
  for (const element of controlledDispatchElements(target)) {
    recordControlledValueDispatch(element)
  }
}

function controlledResetMatchesDispatch(element) {
  return (
    element.__ashUiDispatchedValueVersion === controlledValueVersion(element) &&
    element.__ashUiDispatchedValue === element.value
  )
}

function controlledValueIsServerAcknowledged(element) {
  return element.__ashUiServerValueVersion === controlledValueVersion(element)
}

function syncControlledElementValue(element, serverValue) {
  if (element.value === serverValue) {
    element.__ashUiServerValueVersion = controlledValueVersion(element)
    return
  }

  const activeElement =
    element.ownerDocument?.activeElement || globalThis.document?.activeElement

  if (activeElement === element) {
    if (
      !controlledResetMatchesDispatch(element) &&
      !controlledValueIsServerAcknowledged(element)
    ) {
      return
    }
  }

  element.value = serverValue
  advanceControlledValueVersion(element)
  element.__ashUiServerValueVersion = controlledValueVersion(element)
}

function syncControlledValue(hook) {
  const root = hook?.el
  if (!root) return

  const elements = ["INPUT", "TEXTAREA", "SELECT"].includes(root.tagName)
    ? [root]
    : Array.from(root.querySelectorAll?.("input[value],textarea[value],select[value]") || [])

  for (const element of elements) {
    if (element.type === "file") continue

    const serverValue = element.getAttribute("value")
    if (serverValue === null) continue

    // Focused controls keep in-flight edits. A server update may cross a later
    // edit, so it is applied only while the DOM still represents the value
    // captured by the latest dispatch (or an acknowledged, unedited server
    // value). This covers both resets and authoritative button-driven edits.
    // Unfocused controls continue to accept every server update.
    syncControlledElementValue(element, serverValue)
  }
}

// Slack-style transcript follow: a scroll container marked
// `data-stick-bottom` pins to its most recent content. It jumps to the bottom
// on first sight (latest message visible on open), and on every later patch it
// follows the end ONLY when the user was already at the bottom — reading back
// through history is never yanked away. `data-stick-bottom` is the explicit
// AshUi boundary; the behaviour is a tiny scroll affordance, not state.
const STICK_BOTTOM_THRESHOLD_PX = 48

function stickTargetAtBottom(element) {
  return element.scrollHeight - element.clientHeight - element.scrollTop <= STICK_BOTTOM_THRESHOLD_PX
}

function initStickBottomElement(element) {
  const anchorHeld = element.__ashUiAnchorHeld === true
  element.__ashUiStickBottomBound = true
  element.__ashUiAtBottom = !anchorHeld
  element.__ashUiAnchorHeld = anchorHeld

  const releaseAnchorHold = () => {
    if (!element.__ashUiAnchorHeld) return
    element.__ashUiAnchorHeld = false
    element.__ashUiAtBottom = stickTargetAtBottom(element)
  }

  for (const eventName of ["wheel", "touchmove", "pointerdown", "keydown"]) {
    element.addEventListener(eventName, releaseAnchorHold, {passive: true})
  }

  element.addEventListener(
    "scroll",
    () => {
      if (element.__ashUiAnchorHeld) return
      element.__ashUiAtBottom = stickTargetAtBottom(element)
    },
    {passive: true}
  )

  if (!anchorHeld) {
    element.scrollTop = element.scrollHeight
    element.__ashUiAtBottom = true
  }
}

function followStickBottomTargets() {
  for (const element of document.querySelectorAll?.("[data-stick-bottom]") || []) {
    if (!element.__ashUiStickBottomBound) {
      initStickBottomElement(element)
    } else if (element.__ashUiAtBottom && !element.__ashUiAnchorHeld) {
      element.scrollTop = element.scrollHeight
    }
  }
}

// The AshUiClient LiveView hook is optional (most routed apps do not
// attach it), so transcript-follow is driven from the global DOM bridge: a
// document MutationObserver pins every `[data-stick-bottom]` container to its
// newest content — coalesced to a frame so appended messages never thrash
// layout.
function installStickToBottom() {
  if (window.__ashUiStickBottomInstalled) return
  window.__ashUiStickBottomInstalled = true

  let scheduled = false
  const run = () => {
    scheduled = false
    followStickBottomTargets()
  }
  const schedule = () => {
    if (scheduled) return
    scheduled = true
    ;(window.requestAnimationFrame || (fn => setTimeout(fn, 0)))(run)
  }

  followStickBottomTargets()
  new MutationObserver(schedule).observe(document, {subtree: true, childList: true})
}

// The server clears an enter-to-submit control on a successful submit, but the
// patch runtime locks focused inputs. Clear optimistically after dispatch while
// the element's edit version and value still match the dispatched snapshot; a
// new edit that lands before the next task must survive.
function clearEnterSubmitControl(element) {
  if (!element) return
  const tag = element.tagName
  if (tag !== "TEXTAREA" && tag !== "INPUT") return

  const keyFilter =
    element.getAttribute?.("data-ash-ui-key") || element.getAttribute?.("phx-key")
  if (keyFilter !== "Enter" || element.value === "") return

  const dispatchedVersion = controlledValueVersion(element)
  const dispatchedValue = element.value

  ;(window.setTimeout || setTimeout)(() => {
    if (
      controlledValueVersion(element) !== dispatchedVersion ||
      element.value !== dispatchedValue
    ) {
      return
    }

    element.value = ""
    advanceControlledValueVersion(element)
  })
}

function installEnterSubmitReset(liveSocket) {
  if (window.__ashUiEnterSubmitResetInstalled) return
  window.__ashUiEnterSubmitResetInstalled = true

  window.addEventListener(
    "keydown",
    event => {
      const attribute =
        typeof liveSocket?.binding === "function" ? liveSocket.binding("keydown") : "phx-keydown"
      const target = closestElementWithAttribute(event.target, attribute)

      if (!target || !keyFilterAllowsEvent(target, event)) return

      // The form payload and edit epoch are captured by the same handler that
      // owns the optimistic clear. Both captures happen synchronously before
      // the clear is scheduled, so LiveView may serialize later without
      // consulting a cleared control.
      captureEventFormPayload(event, target)
      recordControlledDispatch(target)
      clearEnterSubmitControl(event.target)
    },
    {capture: true}
  )
}

function firstClientAction(element, predicate) {
  return clientActionData(element).find(predicate)
}

function uploadAction(element) {
  return firstClientAction(element, action => {
    const using = action?.using
    const opts = action?.opts || {}

    return (
      using === "file_upload" ||
      using === "upload" ||
      using === "multipart_upload" ||
      opts.file_upload === true
    )
  })
}

function csrfToken() {
  return document
    ?.querySelector?.("meta[name='csrf-token']")
    ?.getAttribute?.("content")
}

function uploadStatusElement(input, action) {
  const selector = action?.opts?.status_selector
  if (selector) return document?.querySelector?.(selector)

  const scope = input?.closest?.("[data-ash-ui-upload-scope]")
  return scope?.querySelector?.("[data-ash-ui-upload-status]") || null
}

function uploadControlElement(input, action) {
  const selector = action?.opts?.control_selector
  if (selector) return document?.querySelector?.(selector)

  const id = input?.getAttribute?.("id")
  if (!id) return null

  const escapedId = window.CSS?.escape ? CSS.escape(id) : id.replace(/"/g, '\\"')
  return document?.querySelector?.(`label[for="${escapedId}"]`)
}

function setUploadState(input, action, message, busy = false) {
  const status = uploadStatusElement(input, action)
  if (status) status.textContent = message || ""

  if (input) input.disabled = busy

  const control = uploadControlElement(input, action)
  if (control) control.setAttribute("aria-disabled", busy ? "true" : "false")
}

function stripExtension(filename) {
  return String(filename || "").replace(/\.[^/.]+$/, "")
}

function responseValue(payload, path) {
  if (!Array.isArray(path) || path.length === 0) return payload

  return path.reduce((value, segment) => {
    if (!isObject(value)) return undefined
    return value[segment]
  }, payload)
}

function appendUploadParams(data, opts, file) {
  const params = opts.params
  if (isObject(params)) {
    for (const [key, value] of Object.entries(params)) {
      if (value !== undefined && value !== null) data.append(key, value)
    }
  }

  if (opts.title_from_filename && opts.title_field) {
    data.append(opts.title_field, stripExtension(file.name))
  }
}

function uploadRedirectUrl(payload, action) {
  const opts = action?.opts || {}
  const redirectTo = opts.redirect_to
  if (redirectTo) return redirectTo

  const redirectParam = opts.redirect_param
  if (!redirectParam) return null

  const idPath = opts.response_id_path || ["data", "id"]
  const id = responseValue(payload, idPath)
  if (!id) return null

  const nextUrl = new URL(window.location.href)

  if (opts.redirect_path) {
    nextUrl.pathname = opts.redirect_path
  }

  nextUrl.searchParams.set(redirectParam, id)

  for (const param of opts.preserve_params || []) {
    const value = new URL(window.location.href).searchParams.get(param)
    if (value) nextUrl.searchParams.set(param, value)
  }

  return nextUrl.toString()
}

async function uploadFile(input, action) {
  const opts = action?.opts || {}
  const [file] = input?.files || []
  if (!file) return

  const url = opts.url || opts.path
  if (!url) {
    setUploadState(input, action, "Upload target is not configured.", false)
    return
  }

  setUploadState(input, action, opts.busy_message || "Uploading...", true)

  try {
    const data = new FormData()
    data.append(opts.file_field || "file", file)
    appendUploadParams(data, opts, file)

    const headers = {"accept": "application/json"}
    const token = csrfToken()
    if (token) headers["x-csrf-token"] = token

    const response = await fetch(url, {
      method: opts.method || "POST",
      headers,
      body: data,
    })

    const payload = await response.json().catch(() => ({}))

    if (!response.ok) {
      throw new Error(payload?.error || `Upload failed: ${response.status}`)
    }

    const redirectUrl = uploadRedirectUrl(payload, action)
    if (redirectUrl) {
      window.location.assign(redirectUrl)
      return
    }

    setUploadState(input, action, opts.success_message || "Uploaded.", false)
  } catch (error) {
    setUploadState(input, action, error?.message || opts.error_message || "Upload failed.", false)
  } finally {
    if (input) input.value = ""
  }
}

function bindUploadAction(hook) {
  const input = hook?.el
  hook.__ashUiUploadAbortController?.abort?.()
  delete hook.__ashUiUploadAbortController

  const action = uploadAction(input)
  if (!input || !action) return

  const abortController = new AbortController()
  hook.__ashUiUploadAbortController = abortController
  const eventName = action.dom_event || "change"

  input.addEventListener(
    eventName,
    event => {
      if (eventName === "submit") event.preventDefault()
      return uploadFile(input, action)
    },
    {signal: abortController.signal}
  )
}

function closestElementWithAttribute(target, attribute) {
  let current = target

  while (current) {
    if (current?.getAttribute?.(attribute)) return current
    current = current?.parentElement || null
  }

  return null
}

function domOptionMatches(value, eventType) {
  if (!value) return false
  const normalized = String(value)

  return normalized === "true" ||
    normalized === "*" ||
    normalized.split(/\s+/).filter(Boolean).includes(eventType)
}

function optionElementForEvent(target, attribute, eventType) {
  let current = target

  while (current) {
    if (domOptionMatches(current?.getAttribute?.(attribute), eventType)) return current
    current = current?.parentElement || null
  }

  return null
}

// A key-filtered binding (`when: key("Enter")` renders `data-ash-ui-key` /
// `phx-key`) scopes its DOM options to THAT key, unmodified. Without this
// guard, `prevent_default` on a composer's Enter binding swallows every
// keystroke — typing in the input becomes impossible — and Shift+Enter
// (newline) would be eaten too.
function keyFilterAllowsEvent(element, event) {
  if (event.type !== "keydown" && event.type !== "keyup") return true

  const filter =
    element?.getAttribute?.("data-ash-ui-key") || element?.getAttribute?.("phx-key")

  if (!filter) return true
  if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return false

  return event.key === filter
}

function installDomOptionShim(attribute, callback) {
  for (const eventName of SHIMMED_DOM_EVENTS) {
    window.addEventListener(
      eventName,
      event => {
        const element = optionElementForEvent(event.target, attribute, event.type)
        if (element && keyFilterAllowsEvent(element, event)) callback(event)
      },
      {capture: true}
    )
  }
}

function pointerEventPayload(event) {
  return {
    clientX: event.clientX,
    clientY: event.clientY,
    pageX: event.pageX,
    pageY: event.pageY,
    screenX: event.screenX,
    screenY: event.screenY,
    button: event.button,
    buttons: event.buttons,
    ctrlKey: event.ctrlKey,
    metaKey: event.metaKey,
    shiftKey: event.shiftKey,
    altKey: event.altKey
  }
}

function phxValuePayload(element, liveSocket) {
  const prefix = typeof liveSocket?.binding === "function" ? liveSocket.binding("value-") : "phx-value-"
  const payload = {}

  for (const attribute of Array.from(element?.attributes || [])) {
    if (!attribute.name.startsWith(prefix)) continue

    const name = attribute.name.slice(prefix.length)
    payload[name] = attribute.value
  }

  return payload
}

function pushLiveViewDomEvent(liveSocket, target, eventType, eventName, payload) {
  if (typeof liveSocket?.withinOwners !== "function") return false

  let pushed = false

  liveSocket.withinOwners(target, (view, targetContext) => {
    if (typeof view?.pushWithReply !== "function" || typeof view?.putRef !== "function") return

    const eventPayload = {
      type: eventType,
      event: eventName,
      value: payload
    }

    if (typeof view.targetComponentID === "function") {
      const componentId = view.targetComponentID(target, targetContext, {})

      if (Number.isInteger(componentId)) {
        eventPayload.cid = componentId
      }
    }

    view
      .pushWithReply(
        replyPayload =>
          view.putRef([{el: target, loading: true, lock: true}], eventName, eventType, {
            payload: replyPayload?.payload
          }),
        "event",
        eventPayload
      )
      .catch(error => console.error("Failed to push AshUi DOM event", error))

    pushed = true
  })

  return pushed
}

function backpressureInputPushes(view) {
  if (
    !view ||
    backpressuredViews.has(view) ||
    typeof view.pushInput !== "function"
  ) {
    return view
  }

  const pushInput = view.pushInput.bind(view)

  view.pushInput = (...args) => {
    const input = args[0]

    // LiveView's upload preflight has its own ordered lifecycle. Ordinary
    // value-bearing controls are replacement-state events, so only they use
    // the one-in-flight/latest-pending queue.
    if (!input || input.type === "file") return pushInput(...args)

    let state = inputPushStates.get(input)

    if (!state) {
      state = {inFlight: false, pending: null}
      inputPushStates.set(input, state)
    }

    if (state.inFlight) {
      state.pending = args
      return
    }

    const dispatch = pendingArgs => {
      if (pendingArgs[0]?.isConnected === false) return

      state.inFlight = true
      const callback = pendingArgs[5]
      const dispatchedArgs = pendingArgs.slice()

      dispatchedArgs[5] = response => {
        try {
          callback?.(response)
        } finally {
          state.inFlight = false
          const latest = state.pending
          state.pending = null
          if (latest) dispatch(latest)
        }
      }

      try {
        return pushInput(...dispatchedArgs)
      } catch (error) {
        state.inFlight = false
        throw error
      }
    }

    return dispatch(args)
  }

  backpressuredViews.add(view)
  return view
}

export function installLiveViewInputPushBackpressure(liveSocket) {
  if (
    !liveSocket ||
    liveSocket.__ashUiInputPushBackpressureInstalled ||
    typeof liveSocket.owner !== "function"
  ) {
    return
  }

  liveSocket.__ashUiInputPushBackpressureInstalled = true
  const owner = liveSocket.owner.bind(liveSocket)

  // LiveView resolves both root and component target views through owner/2.
  // Patch each resolved view before its event executor reaches pushInput.
  liveSocket.owner = (element, callback) => {
    if (typeof callback !== "function") {
      return backpressureInputPushes(owner(element))
    }

    return owner(element, view => callback(backpressureInputPushes(view)))
  }
}

function controlledElements(root) {
  if (!root) return []

  const own = ["INPUT", "TEXTAREA", "SELECT"].includes(root.tagName) &&
    root.type !== "file" &&
    root.getAttribute?.("value") !== null

  const descendants = Array.from(
    root.querySelectorAll?.("input[value],textarea[value],select[value]") || []
  ).filter(element => element.type !== "file")

  return own ? [root, ...descendants] : descendants
}

function syncControlledElements(root) {
  for (const element of controlledElements(root)) {
    const serverValue = element.getAttribute("value")
    if (serverValue !== null) syncControlledElementValue(element, serverValue)
  }
}

// A narrowed LiveView patch can change a control without updating the hooked
// ancestor, so no hook `updated` callback runs. Mirror every server `value`
// mutation through the same dispatch/edit-version gate, and initialize
// controls materialized by a conditional-arm patch from their server values.
function installControlledValueSync() {
  const observer = new MutationObserver(mutations => {
    for (const mutation of mutations) {
      if (mutation.type === "attributes") {
        syncControlledElements(mutation.target)
      } else if (mutation.type === "childList") {
        for (const node of mutation.addedNodes) syncControlledElements(node)
      }
    }
  })

  observer.observe(document, {
    subtree: true,
    attributes: true,
    attributeFilter: ["value"],
    childList: true
  })
}

function installControlledDispatchTracking(liveSocket) {
  if (window.__ashUiControlledDispatchTrackingInstalled) return
  window.__ashUiControlledDispatchTrackingInstalled = true

  for (const eventName of ["input", "change"]) {
    window.addEventListener(
      eventName,
      event => recordControlledValueEdit(event.target),
      {capture: true}
    )
  }

  window.addEventListener(
    "submit",
    event => {
      const attribute =
        typeof liveSocket?.binding === "function" ? liveSocket.binding("submit") : "phx-submit"
      const form = closestElementWithAttribute(event.target, attribute)
      if (form) recordControlledDispatch(form)
    },
    {capture: true}
  )

  for (const eventName of ["keyup", "click"]) {
    window.addEventListener(
      eventName,
      event => {
        const attribute =
          typeof liveSocket?.binding === "function"
            ? liveSocket.binding(eventName)
            : `phx-${eventName}`
        const target = closestElementWithAttribute(event.target, attribute)

        if (target && keyFilterAllowsEvent(target, event)) {
          captureEventFormPayload(event, target)
          recordControlledDispatch(target)
        }
      },
      {capture: true}
    )
  }
}

export function installAshUiDomEventBridge(liveSocket) {
  if (!liveSocket || liveSocket.__ashUiDomEventBridgeInstalled) return
  liveSocket.__ashUiDomEventBridgeInstalled = true

  installLiveViewInputPushBackpressure(liveSocket)
  installDomOptionShim("data-ash-ui-prevent-default", event => event.preventDefault?.())
  installDomOptionShim("data-ash-ui-stop-propagation", event => event.stopPropagation?.())
  installControlledDispatchTracking(liveSocket)
  installControlledValueSync()
  installAshUiDomCommandBridge()
  installStickToBottom()
  installEnterSubmitReset(liveSocket)

  window.addEventListener(
    "contextmenu",
    event => {
      const attribute = typeof liveSocket.binding === "function" ? liveSocket.binding("contextmenu") : "phx-contextmenu"
      const target = closestElementWithAttribute(event.target, attribute)
      const eventName = target?.getAttribute?.(attribute)

      if (!target || !eventName) return

      event.preventDefault()

      pushLiveViewDomEvent(liveSocket, target, "contextmenu", eventName, {
        ...pointerEventPayload(event),
        ...phxValuePayload(target, liveSocket)
      })
    },
    {capture: true}
  )
}

const pendingScrollReveals = new WeakMap()
const scrollRevealNotices = new WeakMap()
const SCROLL_REVEAL_TIMEOUT_MS = 10_000
const SCROLL_REVEAL_CANCEL_KEYS = new Set([
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  "ArrowUp",
  "End",
  "Home",
  "PageDown",
  "PageUp",
  " "
])

function commandTarget(payload = {}, commandDocument = globalThis.document) {
  if (payload.selector) return commandDocument?.querySelector?.(payload.selector)
  if (payload.to) return commandDocument?.querySelector?.(payload.to)
  if (payload.part) {
    return commandDocument?.querySelector?.(`[part~="${cssEscape(payload.part)}"]`)
  }

  const id = payload.id || payload.dom_id || payload["dom-id"]
  if (!id) return null

  return (
    commandDocument?.getElementById?.(id) ||
    commandDocument?.querySelector?.(`#${cssEscape(id)}`)
  )
}

function clearScrollRevealNotice(commandDocument) {
  const notice = scrollRevealNotices.get(commandDocument)
  if (!notice) return

  scrollRevealNotices.delete(commandDocument)

  if (notice.synthetic) {
    notice.element?.remove?.()
  } else {
    notice.element?.removeAttribute?.("data-ash-ui-reveal-unresolved")
  }
}

function finishPendingScrollReveal(commandDocument, pending) {
  if (pendingScrollReveals.get(commandDocument) !== pending) return false

  pendingScrollReveals.delete(commandDocument)
  pending.observer?.disconnect?.()
  pending.clearTimeout?.(pending.timer)
  return true
}

function cancelPendingScrollReveal(commandDocument) {
  const pending = pendingScrollReveals.get(commandDocument)
  if (pending) finishPendingScrollReveal(commandDocument, pending)
}

function performScrollReveal(target, detail) {
  if (typeof target?.scrollIntoView !== "function") return false

  const stickBottom = target.closest?.("[data-stick-bottom]")
  if (stickBottom) {
    stickBottom.__ashUiAnchorHeld = true
    stickBottom.__ashUiAtBottom = false
  }

  target.scrollIntoView(detail?.options || {block: "nearest", inline: "nearest"})
  return true
}

function surfaceUnresolvedScrollReveal(commandDocument, browserWindow, detail) {
  const failureDetail = {...detail, reason: "target-timeout"}
  const CustomEventClass = browserWindow?.CustomEvent || globalThis.CustomEvent

  if (typeof CustomEventClass === "function") {
    commandDocument?.dispatchEvent?.(
      new CustomEventClass("ash-ui:scroll-into-view-unresolved", {
        detail: failureDetail
      })
    )
  }

  const existingNotice = commandDocument?.querySelector?.('[part~="document_notice"]')
  if (existingNotice) {
    existingNotice.hidden = false
    existingNotice.setAttribute?.("data-ash-ui-reveal-unresolved", "true")
    existingNotice.setAttribute?.("role", existingNotice.getAttribute?.("role") || "status")
    existingNotice.setAttribute?.("aria-live", existingNotice.getAttribute?.("aria-live") || "polite")
    scrollRevealNotices.set(commandDocument, {element: existingNotice, synthetic: false})
    return existingNotice
  }

  const notice = commandDocument?.createElement?.("div")
  if (!notice) return null

  notice.setAttribute?.("part", "document_notice")
  notice.setAttribute?.("role", "status")
  notice.setAttribute?.("aria-live", "polite")
  notice.setAttribute?.("data-ash-ui-reveal-unresolved", "true")
  notice.textContent = "The referenced content could not be revealed."

  const noticeParent = commandDocument?.body || commandDocument?.documentElement
  if (typeof noticeParent?.prepend === "function") {
    noticeParent.prepend(notice)
  } else {
    noticeParent?.appendChild?.(notice)
  }

  scrollRevealNotices.set(commandDocument, {element: notice, synthetic: true})
  return notice
}

export function requestAshUiScrollIntoView(detail = {}, runtime = {}) {
  const commandDocument = runtime.document || globalThis.document
  const browserWindow = runtime.window || globalThis.window
  if (!commandDocument) return "unavailable"

  cancelPendingScrollReveal(commandDocument)
  clearScrollRevealNotice(commandDocument)

  const immediateTarget = commandTarget(detail, commandDocument)
  if (performScrollReveal(immediateTarget, detail)) return "revealed"

  const ObserverClass =
    runtime.MutationObserver || browserWindow?.MutationObserver || globalThis.MutationObserver
  const scheduleTimeout =
    runtime.setTimeout || browserWindow?.setTimeout?.bind(browserWindow) || globalThis.setTimeout
  const clearTimeout =
    runtime.clearTimeout || browserWindow?.clearTimeout?.bind(browserWindow) || globalThis.clearTimeout
  const pending = {detail, observer: null, timer: null, clearTimeout}

  const retry = () => {
    if (pendingScrollReveals.get(commandDocument) !== pending) return

    const target = commandTarget(detail, commandDocument)
    if (!target || !finishPendingScrollReveal(commandDocument, pending)) return

    performScrollReveal(target, detail)
  }

  pendingScrollReveals.set(commandDocument, pending)

  if (typeof ObserverClass === "function") {
    pending.observer = new ObserverClass(retry)
    pending.observer.observe(commandDocument.documentElement || commandDocument, {
      attributeFilter: ["id", "part"],
      attributes: true,
      childList: true,
      subtree: true
    })
  }

  if (typeof scheduleTimeout === "function") {
    pending.timer = scheduleTimeout(() => {
      if (!finishPendingScrollReveal(commandDocument, pending)) return
      surfaceUnresolvedScrollReveal(commandDocument, browserWindow, detail)
    }, runtime.timeoutMs ?? SCROLL_REVEAL_TIMEOUT_MS)
  }

  return "pending"
}

export function installAshUiDomCommandBridge() {
  if (window.__ashUiDomCommandBridgeInstalled) return
  window.__ashUiDomCommandBridgeInstalled = true

  window.addEventListener("phx:ash_ui:focus", event => {
    const target = commandTarget(event.detail || {})
    if (typeof target?.focus === "function") {
      const detail = event.detail || {}
      target.focus({preventScroll: (detail.prevent_scroll ?? detail["prevent-scroll"]) !== false})
    }
  })

  window.addEventListener("phx:ash_ui:scroll-into-view", event => {
    requestAshUiScrollIntoView(event.detail || {})
  })

  for (const eventName of ["pointerdown", "touchstart", "wheel"]) {
    window.addEventListener(
      eventName,
      () => cancelPendingScrollReveal(document),
      {capture: true, passive: true}
    )
  }

  window.addEventListener(
    "keydown",
    event => {
      if (SCROLL_REVEAL_CANCEL_KEYS.has(event.key)) cancelPendingScrollReveal(document)
    },
    {capture: true}
  )

  window.addEventListener("phx:ash_ui:select-text", event => {
    const target = commandTarget(event.detail || {})
    if (typeof target?.select === "function") {
      target.select()
    } else if (target && document?.createRange && window?.getSelection) {
      const range = document.createRange()
      range.selectNodeContents(target)
      const selection = window.getSelection()
      selection.removeAllRanges()
      selection.addRange(range)
    }
  })
}

// Live AshUiClient hook instances, tracked so a runtime that registers
// AFTER the LiveSocket boots (an async module loader finishing its import) can
// be retro-mounted onto elements that are already in the DOM.
const liveClientHookInstances = new Set()

const ashUiBaseHooks = {
  ...phoenixIslandBinding.hooks,

  AshUiClient: {
    mounted() {
      liveClientHookInstances.add(this)
      installBlueprintComponentEventDispatcher(this)
      installBlueprintClientActionDispatcher(this)
      bindExternalCommandDispatch(this)
      bindComponentEventDispatch(this)
      bindUploadAction(this)
      syncControlledValue(this)
      focusBlueprintTarget(this)
    },

    updated() {
      installBlueprintComponentEventDispatcher(this)
      installBlueprintClientActionDispatcher(this)
      bindExternalCommandDispatch(this)
      bindComponentEventDispatch(this)
      bindUploadAction(this)
      syncControlledValue(this)
      focusBlueprintTarget(this)
    },

    destroyed() {
      liveClientHookInstances.delete(this)
      this.__ashUiComponentEventAbortController?.abort?.()
      this.__ashUiUploadAbortController?.abort?.()
      this.__ashUiExternalCommandAbortController?.abort?.()
    }
  }
}

function installRuntime(runtime) {
  if (typeof runtime?.install === "function") {
    runtime.install()
  }
}

function runtimeHooks(runtime) {
  if (!runtime) return {}

  if (typeof runtime === "function") {
    return runtimeHooks(runtime())
  }

  installRuntime(runtime)

  if (typeof runtime.clientHooks === "function") {
    return runtime.clientHooks() || {}
  }

  if (typeof runtime.createHooks === "function") {
    return runtime.createHooks() || {}
  }

  if (isObject(runtime.hooks)) {
    return runtime.hooks
  }

  if (isObject(runtime)) {
    return runtime
  }

  return {}
}

function composeMethod(methodName, implementations) {
  const methods = implementations
    .map((hook) => hook?.[methodName])
    .filter((method) => typeof method === "function")

  if (methods.length === 0) return undefined

  return function composedLifecycle(...args) {
    for (const method of methods) {
      method.apply(this, args)
    }
  }
}

function composeHook(implementations) {
  const hook = Object.assign({}, ...implementations)

  for (const methodName of LIFECYCLE_METHODS) {
    const method = composeMethod(methodName, implementations)

    if (method) {
      hook[methodName] = method
    }
  }

  return hook
}

function mergeHooks(sources) {
  const grouped = new Map()

  for (const source of sources) {
    if (!isObject(source)) continue

    for (const [hookName, hook] of Object.entries(source)) {
      if (!isObject(hook)) continue

      const hooks = grouped.get(hookName) || []
      hooks.push(hook)
      grouped.set(hookName, hooks)
    }
  }

  const merged = {}

  for (const [hookName, implementations] of grouped.entries()) {
    merged[hookName] = composeHook(implementations)
  }

  return merged
}

// The most recent composed hook set, kept so runtimes that register after the
// LiveSocket boots (async module loaders) can still compose in: the LiveSocket
// holds `merged` by reference, so swapping entries applies to future mounts.
let composedClientState = null

export function createAshUiClientHooks({
  runtimes = [],
  hooks = [],
  baseHooks = {},
  extraHooks = {}
} = {}) {
  const runtimeSources = runtimes.map(runtimeHooks)
  const explicitHooks = Array.isArray(hooks) ? hooks : [hooks]
  const sources = [ashUiBaseHooks, baseHooks, ...runtimeSources, ...explicitHooks, extraHooks]
  const merged = mergeHooks(sources)

  composedClientState = {merged, sources}

  return merged
}

// Compose a runtime that registered AFTER the LiveSocket booted. Future hook
// mounts pick up the new composition through the shared `merged` object;
// elements already in the DOM get the runtime's `mounted` invoked now, and
// their lifecycle methods repointed at the recomposition so later
// updated/destroyed passes include the runtime too.
export function attachAshUiRuntime(runtime) {
  if (!composedClientState) return false

  const source = runtimeHooks(runtime)
  if (!isObject(source)) return true

  composedClientState.sources.push(source)
  const remerged = mergeHooks(composedClientState.sources)

  for (const [hookName, hook] of Object.entries(remerged)) {
    composedClientState.merged[hookName] = hook
  }

  const addition = source.AshUiClient
  const composed = remerged.AshUiClient

  for (const instance of liveClientHookInstances) {
    for (const methodName of LIFECYCLE_METHODS) {
      if (typeof composed?.[methodName] === "function") {
        instance[methodName] = composed[methodName]
      }
    }

    if (typeof addition?.mounted === "function") {
      addition.mounted.call(instance)
    }
  }

  return true
}

export const AshUiClient = {
  createHooks: createAshUiClientHooks
}
