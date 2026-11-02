import assert from "node:assert/strict"
import test from "node:test"

import {createIslandRuntime} from "./island.js"
import {createPhoenixIslandBinding} from "./island_phoenix.js"
import {createDatastarIslandBinding} from "../../packages/ash_ui_datastar/assets/js/island_datastar.js"

function islandRoot(props = {rev: 1}) {
  const attributes = new Map([
    ["data-ash-ui-island", "shared-adapter"],
    ["data-ash-ui-island-props", JSON.stringify(props)],
    ["data-ash-ui-island-events", JSON.stringify({save: "v.shared.save"})]
  ])

  return {
    nodeType: 1,
    isConnected: true,
    getAttribute(name) {
      return attributes.get(name) ?? null
    },
    matches(selector) {
      return selector === "[data-ash-ui-island]" && attributes.has("data-ash-ui-island")
    },
    querySelectorAll() {
      return []
    },
    attributes
  }
}

function installSharedAdapter(runtime, calls) {
  runtime.define("shared-adapter", {
    emitWhile: "suspended",
    create(root, ctx) {
      calls.push(["create", root])

      return {
        props(props) {
          calls.push(["props", props])
        },
        suspend() {
          calls.push(["suspend", ctx.suspended])
        },
        resume() {
          calls.push(["resume", ctx.suspended])
        },
        destroy() {
          calls.push(["destroy", root])
        },
        save(payload) {
          return ctx.emit("save", payload)
        }
      }
    }
  })
}

test("one island.define adapter contract runs unchanged through Phoenix and Datastar", async () => {
  const phoenixCalls = []
  const phoenixPushes = []
  const phoenixRoot = islandRoot()
  const phoenixBinding = createPhoenixIslandBinding()
  const phoenixRuntime = createIslandRuntime({binding: phoenixBinding})

  installSharedAdapter(phoenixRuntime, phoenixCalls)
  const phoenixHook = {
    el: phoenixRoot,
    pushEvent(event, payload) {
      phoenixPushes.push({event, payload})
      return Promise.resolve()
    }
  }

  phoenixBinding.hooks.AshUiIsland.mounted.call(phoenixHook)
  await phoenixRuntime.emitByName("shared-adapter", "save", {rev: 1})
  phoenixBinding.hooks.AshUiIsland.disconnected.call(phoenixHook)
  phoenixBinding.hooks.AshUiIsland.reconnected.call(phoenixHook)
  await phoenixBinding.hooks.AshUiIsland.destroyed.call(phoenixHook)

  let mutationCallback
  const datastarCalls = []
  const datastarFetches = []
  const datastarEvents = []
  const datastarRoot = islandRoot()
  const document = {
    body: {},
    defaultView: {
      CustomEvent: class {
        constructor(type, options) {
          this.type = type
          this.detail = options.detail
        }
      }
    },
    querySelectorAll() {
      return [datastarRoot]
    },
    addEventListener() {},
    removeEventListener() {},
    dispatchEvent(event) {
      datastarEvents.push(event)
    }
  }
  class FakeMutationObserver {
    constructor(callback) {
      mutationCallback = callback
    }
    observe() {}
    disconnect() {}
  }
  const datastarBinding = createDatastarIslandBinding({
    document,
    MutationObserverClass: FakeMutationObserver,
    basePath: "/lane",
    startUpdates: false,
    async fetch(url, options) {
      datastarFetches.push({url, options})
      return {
        ok: true,
        status: 200,
        async text() {
          return (
            "event: datastar-patch-elements\n" +
            "data: selector #counter\n" +
            "data: elements <div id=\"counter\"></div>\n\n"
          )
        }
      }
    }
  })
  const datastarRuntime = createIslandRuntime({binding: datastarBinding})

  installSharedAdapter(datastarRuntime, datastarCalls)
  await datastarRuntime.emitByName("shared-adapter", "save", {rev: 1})

  datastarRoot.attributes.set(
    "data-ash-ui-island-props",
    JSON.stringify({rev: 2})
  )
  mutationCallback([
    {
      type: "attributes",
      target: datastarRoot,
      attributeName: "data-ash-ui-island-props"
    }
  ])
  datastarRoot.isConnected = false
  mutationCallback([
    {type: "childList", addedNodes: [], removedNodes: [datastarRoot]}
  ])
  await Promise.resolve()

  assert.deepEqual(
    phoenixCalls.map(([event, value]) => [event, event === "props" ? value : undefined]),
    [
      ["create", undefined],
      ["props", {rev: 1}],
      ["suspend", undefined],
      ["resume", undefined],
      ["destroy", undefined]
    ]
  )
  assert.deepEqual(phoenixPushes, [
    {
      event: "ash_ui:dispatch",
      payload: {binding: "v.shared.save", rev: 1}
    }
  ])

  assert.deepEqual(
    datastarCalls.map(([event, value]) => [event, event === "props" ? value : undefined]),
    [
      ["create", undefined],
      ["props", {rev: 1}],
      ["props", {rev: 2}],
      ["destroy", undefined]
    ]
  )
  assert.equal(datastarFetches[0].url, "/lane/_ash_ui/dispatch/v.shared.save")
  assert.deepEqual(JSON.parse(datastarFetches[0].options.body), {
    binding: "v.shared.save",
    rev: 1
  })
  assert.equal(datastarEvents[0].type, "datastar-fetch")
  assert.deepEqual(datastarEvents[0].detail.argsRaw, {
    selector: "#counter",
    elements: '<div id="counter"></div>'
  })
})
