const ISLAND_SELECTOR = "[data-ash-ui-island]"
const SYNC_ATTRIBUTES = [
  "data-ash-ui-island",
  "data-ash-ui-island-props",
  "data-ash-ui-island-events"
]
const CLIENT_ID_HEADER = "ash-ui-client-id"
const CLIENT_ID_GLOBAL = "__ashUiDatastarClientId"

function generatedClientId() {
  if (typeof globalThis.crypto?.randomUUID === "function") {
    return globalThis.crypto.randomUUID()
  }

  return `client-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
}

const defaultClientId = globalThis[CLIENT_ID_GLOBAL] || generatedClientId()
globalThis[CLIENT_ID_GLOBAL] = defaultClientId

function islandRoots(node) {
  if (!node || node.nodeType !== 1) return []

  const roots = node.matches?.(ISLAND_SELECTOR) ? [node] : []
  return roots.concat(Array.from(node.querySelectorAll?.(ISLAND_SELECTOR) || []))
}

function scriptBasePath(document) {
  const script = Array.from(document?.scripts || []).find(element =>
    element.src?.includes("/_ash_ui/datastar.js")
  )

  if (!script?.src) return ""

  try {
    const path = new URL(script.src, globalThis.location?.href).pathname
    return path.replace(/\/_ash_ui\/datastar\.js$/, "")
  } catch {
    return ""
  }
}

export function createDatastarIslandBinding({
  document = globalThis.document,
  MutationObserverClass = globalThis.MutationObserver,
  fetch = globalThis.fetch?.bind(globalThis),
  basePath = scriptBasePath(document),
  startUpdates = true,
  clientId = defaultClientId
} = {}) {
  let lifecycle
  let observer
  let updatesRoot
  let readyListener
  let fetchListener

  function updatesPath(path) {
    return `${basePath}/_ash_ui/${path}`
  }

  function attachDocumentRoots() {
    for (const root of document?.querySelectorAll?.(ISLAND_SELECTOR) || []) {
      lifecycle?.onAttach(root)
    }
  }

  function observeMutations(records) {
    const added = new Set()
    const removed = new Set()

    for (const record of records) {
      if (record.type === "attributes") {
        const root = record.target

        if (root?.matches?.(ISLAND_SELECTOR)) {
          lifecycle?.onSync(root)
        } else {
          lifecycle?.onDetach(root, "terminal")
        }

        continue
      }

      for (const node of record.addedNodes || []) {
        for (const root of islandRoots(node)) added.add(root)
      }

      for (const node of record.removedNodes || []) {
        for (const root of islandRoots(node)) removed.add(root)
      }
    }

    // A DOM move appears as remove+add in one observer batch. Its node is
    // still connected, so preserve the root and report only a sync.
    for (const root of removed) {
      if (root.isConnected || added.has(root)) {
        lifecycle?.onSync(root)
      } else {
        lifecycle?.onDetach(root, "terminal")
      }
    }

    for (const root of added) {
      if (!removed.has(root)) lifecycle?.onAttach(root)
    }
  }

  function streamEvent(event) {
    if (event?.detail?.el !== updatesRoot) return

    switch (event.detail.type) {
      case "started":
      case "datastar-patch-elements":
      case "datastar-patch-signals":
        for (const root of document?.querySelectorAll?.(ISLAND_SELECTOR) || []) {
          lifecycle?.onResume(root)
        }
        break

      case "error":
      case "retrying":
      case "retries-failed":
      case "finished":
        for (const root of document?.querySelectorAll?.(ISLAND_SELECTOR) || []) {
          lifecycle?.onSuspend(root)
        }
        break
    }
  }

  function applySse(text, root) {
    const CustomEventClass = document?.defaultView?.CustomEvent || globalThis.CustomEvent
    if (!document?.dispatchEvent || typeof CustomEventClass !== "function") return

    for (const block of String(text || "").split(/\r?\n\r?\n/)) {
      let type
      const values = new Map()

      for (const line of block.split(/\r?\n/)) {
        if (line.startsWith("event: ")) {
          type = line.slice(7)
        } else if (line.startsWith("data: ")) {
          const data = line.slice(6)
          const separator = data.indexOf(" ")
          const key = separator === -1 ? data : data.slice(0, separator)
          const value = separator === -1 ? "" : data.slice(separator + 1)
          values.set(key, [...(values.get(key) || []), value])
        }
      }

      if (!type?.startsWith("datastar")) continue

      document.dispatchEvent(
        new CustomEventClass("datastar-fetch", {
          detail: {
            type,
            el: root,
            argsRaw: Object.fromEntries(
              Array.from(values, ([key, lines]) => [key, lines.join("\n")])
            )
          }
        })
      )
    }
  }

  function installUpdatesStream() {
    if (!startUpdates || updatesRoot || !document?.body || !document.createElement) return

    updatesRoot = document.createElement("span")
    updatesRoot.hidden = true
    updatesRoot.setAttribute("aria-hidden", "true")
    updatesRoot.setAttribute("data-ash-ui-updates-stream", "")
    updatesRoot.setAttribute(
      "data-init",
      `@get('${updatesPath("updates")}', {headers: {'${CLIENT_ID_HEADER}': ` +
        `globalThis.${CLIENT_ID_GLOBAL}}, payload: {}, retry: 'auto'})`
    )
    document.body.appendChild(updatesRoot)
  }

  return {
    observe(callbacks) {
      lifecycle = callbacks
      attachDocumentRoots()

      if (typeof MutationObserverClass === "function" && document) {
        observer = new MutationObserverClass(observeMutations)
        observer.observe(document, {
          subtree: true,
          childList: true,
          attributes: true,
          attributeFilter: SYNC_ATTRIBUTES
        })
      }

      if (document?.addEventListener) {
        fetchListener = streamEvent
        document.addEventListener("datastar-fetch", fetchListener)

        if (document.body) {
          installUpdatesStream()
        } else {
          readyListener = installUpdatesStream
          document.addEventListener("DOMContentLoaded", readyListener, {once: true})
        }
      }

      return () => {
        observer?.disconnect()
        if (fetchListener) document?.removeEventListener?.("datastar-fetch", fetchListener)
        if (readyListener) document?.removeEventListener?.("DOMContentLoaded", readyListener)
        updatesRoot?.remove?.()
        observer = undefined
        updatesRoot = undefined
        lifecycle = undefined
      }
    },

    async send(root, binding, payload) {
      if (typeof fetch !== "function") {
        throw new Error("AshUi Datastar island binding requires fetch")
      }

      const response = await fetch(
        `${updatesPath("dispatch")}/${encodeURIComponent(binding)}`,
        {
          method: "POST",
          credentials: "same-origin",
          headers: {
            accept: "text/event-stream",
            "content-type": "application/json",
            [CLIENT_ID_HEADER]: clientId
          },
          body: JSON.stringify({...payload, binding})
        }
      )

      if (!response.ok) {
        throw new Error(`AshUi Datastar island dispatch failed: ${response.status}`)
      }

      // Datastar's native watcher consumes this public event shape too. Feed
      // the dispatch response through it so an emit cannot race the separate
      // long-lived notification stream's subscription.
      applySse(await response.text(), root)
      return response
    }
  }
}
