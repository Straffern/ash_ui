import assert from "node:assert/strict"
import test from "node:test"

import {browserIslandHost} from "./island_host.js"

function fakeDocument() {
  const clicked = []
  const appended = []
  const document = {
    createElement(tag) {
      const element = {
        tagName: tag.toUpperCase(),
        click() { clicked.push({download: this.download, href: this.href, rel: this.rel}) },
        remove() { appended.splice(appended.indexOf(this), 1) }
      }
      return element
    },
    body: {appendChild(element) { appended.push(element) }}
  }
  return {document, clicked, appended}
}

function withTimers(run) {
  const timers = []
  const original = globalThis.setTimeout
  globalThis.setTimeout = (callback, ms) => (timers.push({callback, ms}), timers.length)
  try {
    return {result: run(), timers}
  } finally {
    globalThis.setTimeout = original
  }
}

test("a tab's island host downloads through an anchor, revokes its URL late, and offers nothing else", () => {
  const {document, clicked, appended} = fakeDocument()
  const host = browserIslandHost(document)
  assert.deepEqual(host.capabilities, {downloadFile: true})
  assert.equal(host.sendMessage, undefined)
  assert.equal(host.updateModelContext, undefined)
  const {result, timers} = withTimers(() => host.downloadFile({contents: [
    {type: "resource", resource: {uri: "file:///part%201.stl", mimeType: "model/stl", text: "solid"}},
    {type: "resource", resource: {uri: "file:///100%.txt", blob: btoa("raw")}}
  ]}))
  assert.deepEqual(result, {})
  // A well-formed name is decoded; a malformed one falls back to the raw last segment.
  assert.deepEqual(clicked.map(({download}) => download), ["part 1.stl", "100%.txt"])
  assert.ok(clicked.every(({href}) => href.startsWith("blob:")))
  assert.deepEqual(appended, [])
  assert.deepEqual(timers.map(({ms}) => ms), [40000, 40000])
  for (const {callback} of timers) callback()
})

test("a tab's island host reports an error when nothing downloadable was offered", () => {
  const {document, clicked} = fakeDocument()
  const host = browserIslandHost(document)
  assert.deepEqual(host.downloadFile({contents: [{type: "text", text: "no resource"}]}), {isError: true})
  assert.deepEqual(host.downloadFile(), {isError: true})
  assert.deepEqual(clicked, [])
})

test("the client's island runtime hands a mounted island the tab's host", async () => {
  const {document} = fakeDocument()
  const previous = globalThis.document
  globalThis.document = document
  let client
  try {
    client = await import("./client.js?island-host")
  } finally {
    if (previous === undefined) delete globalThis.document
    else globalThis.document = previous
  }
  const attributes = new Map([["data-ash-ui-island", "host-probe"]])
  const el = {getAttribute: (name) => attributes.get(name) ?? null}
  const hooks = client.createAshUiClientHooks()
  hooks.AshUiIsland.mounted.call({el, pushEvent() {}})
  let ctx
  client.island.define("host-probe", {create(_root, context) { ctx = context; return {} }})
  assert.deepEqual(ctx.host.capabilities, {downloadFile: true, sendMessage: false, updateModelContext: false})
  assert.equal(typeof ctx.host.downloadFile, "function")
  assert.equal(ctx.host.sendMessage, undefined)
})
