import assert from "node:assert/strict"
import {spawn} from "node:child_process"
import {existsSync, readFileSync} from "node:fs"
import {createServer} from "node:http"
import {fileURLToPath} from "node:url"
import test from "node:test"

const liveViewModulePath = fileURLToPath(
  new URL(
    "../../packages/ash_ui_phoenix/deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js",
    import.meta.url
  )
)

// The distributed ESM bundle contains the exact production Rendered and
// DOMPatch implementations but only exports LiveSocket's public API. Appending
// a test-only export exercises those private production classes byte-for-byte.
const liveViewHarnessModule =
  readFileSync(liveViewModulePath, "utf8") +
  "\nexport {Rendered, DOMPatch, dom_default as DOM};\n"
const clientModule = readFileSync(new URL("./client.js", import.meta.url), "utf8")
const islandModule = readFileSync(new URL("./island.js", import.meta.url), "utf8")
const islandPhoenixModule = readFileSync(new URL("./island_phoenix.js", import.meta.url), "utf8")
const islandHostModule = readFileSync(new URL("./island_host.js", import.meta.url), "utf8")

const harnessHtml = String.raw`<!doctype html>
<html>
  <body>
    <pre id="result" data-status="running"></pre>
    <script type="module">
      import {DOM, DOMPatch, Rendered} from "/phoenix_live_view_harness.mjs"
      import {installAshUiDomEventBridge} from "/client.js"

      const resultEl = document.querySelector("#result")
      const ROW_COUNT = 120
      const INSERT_AT = 1
      const COMPOSER_CHAR_COUNT = 1000
      const COMPOSER_LATENCY_MS = 500
      const rowStatics = [
        '<li data-ref-uri="',
        '" aria-label="',
        '"><button title="',
        '" data-ash-ui-binding-click="',
        '"><span data-row-label="',
        '">',
        "</span></button></li>"
      ]

      function row(index) {
        return {
          id: "row-" + index,
          label: "Row " + index,
          binding: "tree.row-" + index + ".click"
        }
      }

      function renderedRow(value, rooted) {
        const rendered = {
          0: value.id,
          1: value.label,
          2: value.label,
          3: value.binding,
          4: value.label,
          5: value.label
        }

        if (!rooted) return rendered

        rendered.s = rowStatics
        rendered.r = 1
        return {0: rendered}
      }

      function initialDiff(rows, rooted) {
        const keyed = {kc: rows.length}
        rows.forEach((value, index) => {
          keyed[index] = renderedRow(value, rooted)
        })

        return {
          0: {s: rooted ? ["", ""] : rowStatics, k: keyed},
          s: ['<section part="patch-breadth"><ul>', "</ul></section>"],
          r: 1
        }
      }

      function insertionDiff(rows, inserted, rooted) {
        const keyed = {kc: rows.length + 1}
        keyed[INSERT_AT] = renderedRow(inserted, rooted)

        for (let index = INSERT_AT + 1; index < rows.length + 1; index++) {
          keyed[index] = index - 1
        }

        return {0: {k: keyed}}
      }

      function fakeView(container) {
        const liveSocket = {
          binding(name) {
            return "phx-" + name
          },
          destroyViewByEl() {},
          getActiveElement() {
            return document.activeElement
          },
          isDebugEnabled() {
            return false
          },
          silenceEvents(callback) {
            callback()
          },
          time(_label, callback) {
            callback()
          },
          transitionRemoves(_elements, callback) {
            callback()
          },
          unload() {}
        }

        return {
          id: container.id,
          root: container,
          liveSocket,
          portalElementIds: new Set(),
          dropPortalElementId(id) {
            this.portalElementIds.delete(id)
          },
          ownsElement() {
            return true
          },
          pushPortalElementId(id) {
            this.portalElementIds.add(id)
          }
        }
      }

      function patchHtml(container, html, isJoin = false) {
        new DOMPatch(
          fakeView(container),
          container,
          container.id,
          html,
          new Set(),
          null
        ).perform(isJoin)
      }

      function composerMarkup(draft) {
        return (
          '<form id="agent-composer-form" phx-change="ash_ui:dispatch:composer.change">' +
          '<textarea name="text" phx-debounce="100">' +
          draft +
          "</textarea></form>"
        )
      }

      async function runComposerLatencyCycle() {
        const container = document.createElement("div")
        container.id = "composer-latency"
        const initial = composerMarkup("")
        container.innerHTML = initial
        document.body.appendChild(container)
        patchHtml(container, initial, true)

        const composer = container.querySelector("textarea")
        composer.focus()

        let inputPushes = 0
        let recoveryPushes = 0
        let remoteDraft = ""

        const delayedPush = (draft, recovery = false) => {
          const attempt = ++inputPushes
          if (recovery) recoveryPushes++

          return new Promise(resolve => {
            setTimeout(() => {
              // The injected first push fails. It must leave the focused DOM
              // draft intact so form recovery can resend that same value.
              if (attempt !== 1) remoteDraft = draft
              resolve()
            }, COMPOSER_LATENCY_MS)
          })
        }

        let pendingPush

        for (let index = 0; index < COMPOSER_CHAR_COUNT; index++) {
          composer.value += "x"
          const event = new InputEvent("input", {bubbles: true, data: "x"})

          DOM.debounce(
            composer,
            event,
            "phx-debounce",
            "300",
            "phx-throttle",
            "300",
            () => true,
            () => {
              pendingPush = delayedPush(composer.value)
            }
          )
        }

        // One debounce window, followed by the injected network delay.
        await new Promise(resolve => setTimeout(resolve, 350))
        await pendingPush
        const draftAfterFailure = composer.value

        const formDraft = new FormData(container.querySelector("form")).get("text")
        await delayedPush(formDraft, true)
        patchHtml(container, composerMarkup(remoteDraft))

        const result = {
          charCount: composer.value.length,
          draftAfterFailureLength: draftAfterFailure.length,
          inputPushes: inputPushes - recoveryPushes,
          recoveryPushes,
          remoteDraftLength: remoteDraft.length
        }

        container.remove()
        return result
      }

      function islandMarkup(props, arm = "primary") {
        return (
          '<section data-arm="' + arm + '">' +
          '<div id="ash-ui-island-contract" ' +
          'phx-hook="AshUiIsland" phx-update="ignore" ' +
          'data-ash-ui-island="contract" ' +
          'data-ash-ui-island-props="' + props.replace(/"/g, "&quot;") + '">' +
          "</div></section>"
        )
      }

      function directIslandPatch(initial, patch) {
        const container = document.createElement("div")
        container.id = "island-direct-" + Math.random().toString(36).slice(2)
        container.innerHTML = initial
        document.body.appendChild(container)
        patchHtml(container, initial, true)

        const island = container.querySelector("[data-ash-ui-island]")
        const owned = document.createElement("canvas")
        owned.dataset.clientOwned = "true"
        island.appendChild(owned)
        patchHtml(container, patch)

        const survived =
          container.querySelector("[data-ash-ui-island]") === island &&
          island.firstElementChild === owned
        container.remove()
        return survived
      }

      function workbenchShellFixture() {
        return {
          full: {
            0:
              ' data-ash-ui-binding-window-keydown="v.window-keydown" ' +
              'part="workbench_shell" phx-value-binding="v.window-keydown" ' +
              'phx-window-keydown="ash_ui:dispatch:v.window-keydown"',
            1: {s: 0},
            2: {
              0: {
                0: "",
                1: ' aria-hidden="true"',
                2: "",
                3: ' data-open="false"',
                4: ' part="workbench_command_palette" role="dialog"',
                s: 1
              },
              1: {
                0:
                  ' data-ash-ui-binding-keydown="v-2-acontent-0.keydown" ' +
                  'part="workbench_palette_form" ' +
                  'phx-keydown="ash_ui:dispatch:v-2-acontent-0.keydown" ' +
                  'phx-value-binding="v-2-acontent-0.keydown"',
                1: {
                  0:
                    ' autocomplete="off" ' +
                    'data-ash-ui-binding-input="v-2-acontent-0-0.input" ' +
                    'name="palette_query" part="workbench_palette_input" ' +
                    'phx-change="ash_ui:dispatch:v-2-acontent-0-0.input" ' +
                    'phx-value-binding="v-2-acontent-0-0.input" ' +
                    'placeholder="Type a command" type="search"',
                  1: ' value=""',
                  2: "",
                  s: 2
                },
                2: {
                  k: {
                    0: {
                      0: {
                        0: ' aria-selected="true" part="workbench_palette_entry"',
                        1: ' type="button"',
                        2: "Focus Explorer",
                        3: "",
                        s: 3,
                        r: 1
                      }
                    },
                    1: {
                      0: {
                        0: ' part="workbench_palette_entry"',
                        1: ' type="button"',
                        2: "Focus Main",
                        3: "",
                        s: 3,
                        r: 1
                      }
                    },
                    2: {
                      0: {
                        0: ' part="workbench_palette_entry"',
                        1: ' type="button"',
                        2: "Messages: Open Inbox",
                        3: "",
                        s: 3,
                        r: 1
                      }
                    },
                    kc: 3
                  },
                  s: 4
                },
                s: 5,
                r: 1
              },
              s: 6,
              r: 1
            },
            3: {
              0:
                ' data-ash-ui-dom-owner="client" ' +
                'data-ash-ui-island="workbench-gl" ' +
                'data-ash-ui-island-events="{}"',
              1:
                ' data-ash-ui-island-props="' +
                '{&quot;rev&quot;:0,&quot;manifest&quot;:{&quot;rev&quot;:0}}"',
              2:
                ' id="ash-ui-island-workbench-gl" part="div" ' +
                'phx-hook="AshUiIsland" phx-update="ignore"',
              s: 7
            },
            4: "",
            p: {
              0: [""],
              1: ["", "", "", "", "", ""],
              2: ["", "", "", ""],
              3: [
                "<li",
                "><button",
                '><span part="workbench_palette_entry_label">',
                '</span><span part="workbench_palette_entry_keybinding">',
                "</span></button></li>"
              ],
              4: ["", ""],
              5: [
                '<section part="workbench_palette_content"><form',
                "><input",
                '></form><ul part="workbench_palette_entries" role="listbox">',
                "</ul></section>"
              ],
              6: ["<section", ">", "</section>"],
              7: ["", "", "", ""],
              8: [
                "<section",
                '><div aria-live="polite" part="workbench_connection_status">Connected</div>',
                "",
                "<div",
                "></div>",
                "</section>"
              ]
            },
            s: 8,
            r: 1
          },
          diffs: [
            {
              1: {s: 0, r: 1},
              p: {
                0: [
                  '<section aria-live="assertive" part="workbench_notice">' +
                    "Workbench action could not be completed.</section>"
                ]
              }
            },
            {1: {s: 0}, p: {0: [""]}},
            {
              3: {
                1:
                  ' data-ash-ui-island-props="' +
                  '{&quot;rev&quot;:1,&quot;manifest&quot;:{&quot;rev&quot;:1}}"'
              }
            },
            {2: {0: {1: ' aria-hidden="false"', 3: ' data-open="true"'}}},
            {
              2: {
                0: {1: ' aria-hidden="false"', 3: ' data-open="true"'},
                1: {
                  1: {1: ' value="Messages"'},
                  2: {k: {0: 2, kc: 1}}
                }
              }
            },
            {2: {0: {1: ' aria-hidden="true"', 3: ' data-open="false"'}}},
            {
              2: {
                1: {
                  1: {1: ' value=""'},
                  2: {
                    k: {
                      0: {
                        0: {
                          0: ' aria-selected="true" part="workbench_palette_entry"',
                          1: ' type="button"',
                          2: "Focus Explorer",
                          3: "",
                          s: 3,
                          r: 1
                        }
                      },
                      1: {
                        0: {
                          0: ' part="workbench_palette_entry"',
                          1: ' type="button"',
                          2: "Focus Main",
                          3: "",
                          s: 3,
                          r: 1
                        }
                      },
                      2: {
                        0: {
                          0: ' part="workbench_palette_entry"',
                          1: ' type="button"',
                          2: "Messages: Open Inbox",
                          3: "",
                          s: 3,
                          r: 1
                        }
                      },
                      kc: 3
                    }
                  }
                }
              },
              p: {
                3: [
                  "<li",
                  "><button",
                  '><span part="workbench_palette_entry_label">',
                  '</span><span part="workbench_palette_entry_keybinding">',
                  "</span></button></li>"
                ]
              }
            },
            {
              0:
                ' data-ash-ui-binding-window-keydown="v.window-keydown" ' +
                'part="workbench_shell" phx-value-binding="v.window-keydown" ' +
                'phx-window-keydown="ash_ui:dispatch:v.window-keydown"',
              2: {
                0: {1: ' aria-hidden="true"', 3: ' data-open="false"'},
                1: {
                  0:
                    ' data-ash-ui-binding-keydown="v-2-acontent-0.keydown" ' +
                    'part="workbench_palette_form" ' +
                    'phx-keydown="ash_ui:dispatch:v-2-acontent-0.keydown" ' +
                    'phx-value-binding="v-2-acontent-0.keydown"',
                  1: {
                    0:
                      ' aria-invalid="true" autocomplete="off" ' +
                      'data-ash-ui-binding-input="v-2-acontent-0-0.input" ' +
                      'data-ash-ui-error="bad" name="palette_query" ' +
                      'part="workbench_palette_input" ' +
                      'phx-change="ash_ui:dispatch:v-2-acontent-0-0.input" ' +
                      'phx-value-binding="v-2-acontent-0-0.input" ' +
                      'placeholder="Type a command" type="search" value=""',
                    s: 0
                  },
                  2: ""
                }
              },
              p: {0: ["", ""]}
            },
            {
              0:
                ' data-ash-ui-binding-window-keydown="v.window-keydown" ' +
                'part="workbench_shell" phx-value-binding="v.window-keydown" ' +
                'phx-window-keydown="ash_ui:dispatch:v.window-keydown"',
              2: {
                0: {1: ' aria-hidden="true"', 3: ' data-open="false"'},
                1: {
                  0:
                    ' data-ash-ui-binding-keydown="v-2-acontent-0.keydown" ' +
                    'part="workbench_palette_form" ' +
                    'phx-keydown="ash_ui:dispatch:v-2-acontent-0.keydown" ' +
                    'phx-value-binding="v-2-acontent-0.keydown"',
                  1: {
                    0:
                      ' autocomplete="off" ' +
                      'data-ash-ui-binding-input="v-2-acontent-0-0.input" ' +
                      'name="palette_query" part="workbench_palette_input" ' +
                      'phx-change="ash_ui:dispatch:v-2-acontent-0-0.input" ' +
                      'phx-value-binding="v-2-acontent-0-0.input" ' +
                      'placeholder="Type a command" type="search"',
                    1: ' value=""',
                    2: "",
                    s: 0
                  },
                  2: ""
                }
              },
              p: {0: ["", "", "", ""]}
            },
            {4: '<div data-ash-ui-error="page" role="alert">bad</div>'},
            {4: ""}
          ]
        }
      }

      function literalAngleText(element) {
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT)
        const found = []
        let node

        while ((node = walker.nextNode())) {
          if (node.textContent.trim() === ">") found.push(node.textContent)
        }

        return found
      }

      function runWorkbenchShellCycle() {
        const fixture = workbenchShellFixture()
        const rendered = new Rendered("workbench-shell", fixture.full)
        const initial = rendered.toString()
        const container = document.createElement("div")
        container.id = "workbench-shell"
        container.innerHTML = initial.buffer.replace(/\sdata-phx-id="[^"]+"/g, "")
        document.body.appendChild(container)
        patchHtml(container, initial.buffer, true)

        const shell = container
        const textByCycle = [literalAngleText(shell)]

        for (const diff of fixture.diffs) {
          rendered.mergeDiff(diff)
          const patch = rendered.toString()
          patchHtml(container, patch.buffer)
          textByCycle.push(literalAngleText(shell))
        }

        container.remove()
        return textByCycle
      }

      function runIslandSurvival() {
        const rows = [row(0), row(1), row(2)]
        const inserted = {id: "row-new", label: "Inserted", binding: "new.click"}
        const diff = initialDiff(rows, true)
        diff.s = [
          '<section><div id="ash-ui-island-keyed" ' +
            'phx-hook="AshUiIsland" phx-update="ignore" ' +
            'data-ash-ui-island="keyed" ' +
            'data-ash-ui-island-props="{&quot;rev&quot;:1}"></div><ul>',
          "</ul></section>"
        ]

        const rendered = new Rendered("island-keyed", diff)
        const initial = rendered.toString()
        const container = document.createElement("div")
        container.id = "island-keyed"
        container.innerHTML = initial.buffer.replace(/\sdata-phx-id="[^"]+"/g, "")
        document.body.appendChild(container)
        patchHtml(container, initial.buffer, true)

        const island = container.querySelector("[data-ash-ui-island]")
        const owned = document.createElement("canvas")
        owned.dataset.clientOwned = "true"
        island.appendChild(owned)

        rendered.mergeDiff(insertionDiff(rows, inserted, true))
        const keyedPatch = rendered.toString()
        patchHtml(container, keyedPatch.buffer)

        const keyedSplice =
          container.querySelector("[data-ash-ui-island]") === island &&
          island.firstElementChild === owned
        container.remove()

        const plainAttrs = directIslandPatch(
          islandMarkup('{"rev":1}'),
          islandMarkup('{"rev":2}')
        )
        const branchReemit = directIslandPatch(
          islandMarkup('{"rev":1}', "primary"),
          islandMarkup('{"rev":2}', "alternate")
        )

        return {keyedSplice, plainAttrs, branchReemit}
      }

      function runPatch(rooted) {
        const rows = Array.from({length: ROW_COUNT}, (_value, index) => row(index))
        const inserted = {
          id: "row-new",
          label: "Inserted row",
          binding: "tree.row-new.click"
        }
        const rendered = new Rendered("patch-breadth", initialDiff(rows, rooted))
        const initial = rendered.toString()
        const container = document.createElement("div")
        container.id = "patch-breadth"
        container.innerHTML = initial.buffer.replace(/\sdata-phx-id="[^"]+"/g, "")
        document.body.appendChild(container)
        const view = fakeView(container)

        // Match LiveView's real lifecycle: the dead render has no magic ids,
        // then the join patch stamps the client Rendered tree's ids.
        new DOMPatch(
          view,
          container,
          container.id,
          initial.buffer,
          initial.streams,
          null
        ).perform(true)

        const beforeNodes = new Map(
          Array.from(container.querySelectorAll("li")).map(element => [
            element.getAttribute("data-ref-uri"),
            element
          ])
        )
        const magicIdsBefore = container.querySelectorAll("[data-phx-id]").length
        const rootMagicBefore = container.firstElementChild?.getAttribute("data-phx-id")

        rendered.mergeDiff(insertionDiff(rows, inserted, rooted))
        const patch = rendered.toString()
        const patchDocument = new DOMParser().parseFromString(patch.buffer, "text/html")
        const skipShells = patchDocument.querySelectorAll("[data-phx-skip]").length
        const rootMagicPatch = patchDocument.body.firstElementChild?.getAttribute("data-phx-id")
        const patchOrder = Array.from(patchDocument.querySelectorAll("li"), element =>
          element.getAttribute("data-ref-uri")
        )
        const observer = new MutationObserver(() => {})
        observer.observe(container, {
          attributes: true,
          attributeOldValue: true,
          childList: true,
          subtree: true
        })

        const startedAt = performance.now()
        new DOMPatch(
          view,
          container,
          container.id,
          patch.buffer,
          patch.streams,
          null
        ).perform(false)
        const performPatchMs = performance.now() - startedAt
        const records = observer.takeRecords()
        observer.disconnect()

        const mutationTargets = new Set(records.map(record => record.target)).size
        const attributeRecords = records.filter(record => record.type === "attributes")
        const attributes = attributeRecords.length
        const attributeTargets = new Set(attributeRecords.map(record => record.target)).size
        const childList = records.filter(record => record.type === "childList").length
        const order = Array.from(container.querySelectorAll("li"), element =>
          element.getAttribute("data-ref-uri")
        )
        const identityPreserved = rows.every(
          value => beforeNodes.get(value.id) === container.querySelector(
            '[data-ref-uri="' + value.id + '"]'
          )
        )

        container.remove()

        return {
          attributes,
          attributeTargets,
          childList,
          identityPreserved,
          magicIdsBefore,
          mutationRecords: records.length,
          mutationTargets,
          orderCorrect:
            order[INSERT_AT] === inserted.id &&
            order.length === rows.length + 1,
          orderHead: order.slice(0, 5),
          orderLength: order.length,
          orderTail: order.slice(-5),
          patchOrderHead: patchOrder.slice(0, 5),
          patchOrderLength: patchOrder.length,
          performPatchMs,
          rootMagicBefore,
          rootMagicPatch,
          skipShells
        }
      }

      function runNestedKeyedInvalidation() {
        const bodyMarker = "nested-keyed-body"
        const initialDiff = {
          0: {
            s: ["", ""],
            k: {
              kc: 1,
              0: {
                0: {
                  s: [
                    '<article data-message-row="m1"><p>',
                    "</p><div data-reactions>",
                    "</div></article>"
                  ],
                  r: 1,
                  0: {
                    s: ['<span data-message-body>', "</span>"],
                    0: '<p data-body-marker>' + bodyMarker + "</p>"
                  },
                  1: ""
                }
              }
            }
          },
          s: ['<section data-transcript>', "</section>"],
          r: 1
        }
        const reactionPatch = {
          0: {
            k: {
              kc: 1,
              0: {
                0: {
                  1: {
                    s: ['<button aria-label="Toggle 👍 reaction">', "</button>"],
                    k: {kc: 1, 0: {0: "👍"}}
                  }
                }
              }
            }
          }
        }
        const rendered = new Rendered("nested-keyed-invalidation", initialDiff)
        const initial = rendered.toString()
        const container = document.createElement("div")
        container.id = "nested-keyed-invalidation"
        container.innerHTML = initial.buffer.replace(/\sdata-phx-id="[^"]+"/g, "")
        document.body.appendChild(container)
        const view = fakeView(container)

        new DOMPatch(
          view,
          container,
          container.id,
          initial.buffer,
          initial.streams,
          null
        ).perform(true)

        const bodyBefore = container.querySelector("[data-body-marker]")
        rendered.mergeDiff(reactionPatch)
        const patch = rendered.toString()

        new DOMPatch(
          view,
          container,
          container.id,
          patch.buffer,
          patch.streams,
          null
        ).perform(false)

        const bodyAfter = container.querySelector("[data-body-marker]")
        const result = {
          bodyIdentityPreserved: bodyBefore === bodyAfter,
          bodyText: bodyAfter?.textContent,
          chipText: container.querySelector('[aria-label="Toggle 👍 reaction"]')?.textContent,
          wireOmittedBody: !JSON.stringify(reactionPatch).includes(bodyMarker)
        }

        container.remove()
        return result
      }

      async function runConditionalControlSync() {
        const viewBinding = name => "phx-" + name

        const initialDiff = {
          0: "",
          1: ' value=""',
          s: [
            '<section><dialog',
            '><textarea aria-label="existing control"',
            '></textarea><p data-stable-sibling>stable sibling</p></dialog></section>'
          ],
          r: 1
        }
        const openPatch = {
          0: " open",
          1: ' value="existing prefill"'
        }
        const rendered = new Rendered("conditional-control-existing", initialDiff)
        const initial = rendered.toString()
        const container = document.createElement("div")
        container.id = "conditional-control-existing"
        container.innerHTML = initial.buffer.replace(/\sdata-phx-id="[^"]+"/g, "")
        document.body.appendChild(container)
        const view = fakeView(container)

        new DOMPatch(
          view,
          container,
          container.id,
          initial.buffer,
          initial.streams,
          null
        ).perform(true)

        rendered.mergeDiff(openPatch)
        const patch = rendered.toString()
        new DOMPatch(
          view,
          container,
          container.id,
          patch.buffer,
          patch.streams,
          null
        ).perform(false)

        await new Promise(resolve => setTimeout(resolve, 0))
        const rawPatchedAttribute = container.querySelector('textarea')?.getAttribute("value")
        const rawPatchedValue = container.querySelector('textarea')?.value

        // The attribute is on the wire/DOM, but textarea's live value property
        // does not follow a value-attribute mutation. Install the production
        // bridge, then prove the next narrowed value patch is synchronized.
        installAshUiDomEventBridge({binding: viewBinding})
        rendered.mergeDiff({1: ' value="synchronized prefill"'})
        const synchronizedPatch = rendered.toString()
        new DOMPatch(
          view,
          container,
          container.id,
          synchronizedPatch.buffer,
          synchronizedPatch.streams,
          null
        ).perform(false)

        const armInitialDiff = {
          0: "",
          s: ['<section><div data-arm>', '</div><p data-arm-sibling>arm sibling</p></section>'],
          r: 1
        }
        const armPatch = {
          0: {
            s: ['<textarea aria-label="materialized control" value="materialized prefill"></textarea>']
          }
        }
        const armRendered = new Rendered("conditional-control-arm", armInitialDiff)
        const armInitial = armRendered.toString()
        const armContainer = document.createElement("div")
        armContainer.id = "conditional-control-arm"
        armContainer.innerHTML = armInitial.buffer.replace(/\sdata-phx-id="[^"]+"/g, "")
        document.body.appendChild(armContainer)
        const armView = fakeView(armContainer)

        new DOMPatch(
          armView,
          armContainer,
          armContainer.id,
          armInitial.buffer,
          armInitial.streams,
          null
        ).perform(true)

        armRendered.mergeDiff(armPatch)
        const armPatchHtml = armRendered.toString()
        new DOMPatch(
          armView,
          armContainer,
          armContainer.id,
          armPatchHtml.buffer,
          armPatchHtml.streams,
          null
        ).perform(false)

        await new Promise(resolve => setTimeout(resolve, 0))

        const result = {
          rawPatchedAttribute,
          rawPatchedValue,
          existingAttribute: container.querySelector('textarea')?.getAttribute("value"),
          existingValue: container.querySelector('textarea')?.value,
          existingSibling: container.querySelector('[data-stable-sibling]')?.textContent,
          materializedAttribute: armContainer.querySelector('textarea')?.getAttribute("value"),
          materializedValue: armContainer.querySelector('textarea')?.value,
          materializedSibling: armContainer.querySelector('[data-arm-sibling]')?.textContent
        }

        container.remove()
        armContainer.remove()
        return result
      }

      function median(values) {
        const sorted = values.slice().sort((left, right) => left - right)
        return sorted[Math.floor(sorted.length / 2)]
      }

      try {
        // Warm both paths before measuring. Each sample gets fresh client state
        // and DOM, while the production patch code stays JIT-warm.
        runPatch(false)
        runPatch(true)

        const baseline = runPatch(false)
        const rooted = runPatch(true)
        const baselineTimings = []
        const rootedTimings = []

        for (let sample = 0; sample < 9; sample++) {
          baselineTimings.push(runPatch(false).performPatchMs)
          rootedTimings.push(runPatch(true).performPatchMs)
        }

        baseline.performPatchMedianMs = median(baselineTimings)
        rooted.performPatchMedianMs = median(rootedTimings)

        const islands = runIslandSurvival()
        const workbenchShellText = runWorkbenchShellCycle()
        const composer = await runComposerLatencyCycle()
        const nestedInvalidation = runNestedKeyedInvalidation()
        const conditionalControls = await runConditionalControlSync()
        resultEl.dataset.status = "pass"
        resultEl.dataset.payload = encodeURIComponent(
          JSON.stringify({
            baseline,
            rooted,
            islands,
            workbenchShellText,
            composer,
            nestedInvalidation,
            conditionalControls
          })
        )
      } catch (error) {
        resultEl.dataset.status = "fail"
        resultEl.dataset.payload = encodeURIComponent(
          JSON.stringify({message: error.message, stack: error.stack})
        )
      }
    </script>
  </body>
</html>`

const chromiumPath = process.env.CHROME_BIN || [
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
  "/usr/bin/google-chrome",
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
].find(existsSync)

async function launchChromium(url) {
  const child = spawn(
    chromiumPath,
    [
      "--headless=new",
      "--no-sandbox",
      "--disable-background-networking",
      "--disable-dev-shm-usage",
      "--disable-gpu",
      "--dump-dom",
      "--virtual-time-budget=15000",
      url
    ],
    {stdio: ["ignore", "pipe", "pipe"]}
  )

  let stdout = ""
  let stderr = ""
  child.stdout.setEncoding("utf8")
  child.stderr.setEncoding("utf8")
  child.stdout.on("data", chunk => {
    stdout += chunk
  })
  child.stderr.on("data", chunk => {
    stderr += chunk
  })

  const exitCode = await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      child.kill("SIGKILL")
      reject(new Error("Chromium patch-breadth harness timed out"))
    }, 30000)

    child.once("error", error => {
      clearTimeout(timeout)
      reject(error)
    })
    child.once("exit", code => {
      clearTimeout(timeout)
      resolve(code)
    })
  })

  assert.equal(exitCode, 0, stderr)
  return stdout
}

test("LiveView root tracking keeps keyed insertion patch breadth O(changed)", {timeout: 35000, skip: chromiumPath ? false : "set CHROME_BIN to a Chromium binary"}, async () => {
  const server = createServer((request, response) => {
    if (request.url === "/phoenix_live_view_harness.mjs") {
      response.writeHead(200, {"content-type": "text/javascript; charset=utf-8"})
      response.end(liveViewHarnessModule)
    } else if (request.url === "/client.js") {
      response.writeHead(200, {"content-type": "text/javascript; charset=utf-8"})
      response.end(clientModule)
    } else if (request.url === "/island.js") {
      response.writeHead(200, {"content-type": "text/javascript; charset=utf-8"})
      response.end(islandModule)
    } else if (request.url === "/island_phoenix.js") {
      response.writeHead(200, {"content-type": "text/javascript; charset=utf-8"})
      response.end(islandPhoenixModule)
    } else if (request.url === "/island_host.js") {
      response.writeHead(200, {"content-type": "text/javascript; charset=utf-8"})
      response.end(islandHostModule)
    } else {
      response.writeHead(200, {"content-type": "text/html; charset=utf-8"})
      response.end(harnessHtml)
    }
  })

  await new Promise((resolve, reject) => {
    server.once("error", reject)
    server.listen(0, "127.0.0.1", resolve)
  })

  try {
    const address = server.address()
    const output = await launchChromium(`http://127.0.0.1:${address.port}/`)
    const status = output.match(/id="result" data-status="([^"]+)"/)?.[1]
    const encoded = output.match(/data-payload="([^"]+)"/)?.[1]

    assert.equal(
      status,
      "pass",
      encoded ? decodeURIComponent(encoded) : `browser harness output: ${output.slice(-2000)}`
    )
    assert.ok(encoded, "browser harness did not emit metrics")

    const {
      baseline,
      rooted,
      islands,
      workbenchShellText,
      composer,
      nestedInvalidation,
      conditionalControls
    } = JSON.parse(decodeURIComponent(encoded))

    assert.deepEqual(islands, {
      keyedSplice: true,
      plainAttrs: true,
      branchReemit: true
    })
    assert.deepEqual(workbenchShellText, [[], [], [], [], [], [], [], [], [], [], [], []])
    assert.deepEqual(composer, {
      charCount: 1000,
      draftAfterFailureLength: 1000,
      inputPushes: 1,
      recoveryPushes: 1,
      remoteDraftLength: 1000
    })
    assert.deepEqual(nestedInvalidation, {
      bodyIdentityPreserved: true,
      bodyText: "nested-keyed-body",
      chipText: "👍",
      wireOmittedBody: true
    })
    assert.deepEqual(conditionalControls, {
      rawPatchedAttribute: "existing prefill",
      rawPatchedValue: "",
      existingAttribute: "synchronized prefill",
      existingValue: "synchronized prefill",
      existingSibling: "stable sibling",
      materializedAttribute: "materialized prefill",
      materializedValue: "materialized prefill",
      materializedSibling: "arm sibling"
    })

    assert.equal(rooted.orderCorrect, true)
    assert.equal(rooted.identityPreserved, true)
    assert.equal(rooted.magicIdsBefore, ROW_MAGIC_IDS)
    assert.ok(rooted.skipShells >= 119, `expected PHX_SKIP shells, got ${rooted.skipShells}`)
    assert.ok(
      rooted.mutationTargets <= 4,
      `rooted insertion touched ${rooted.mutationTargets} mutation targets`
    )
    assert.ok(rooted.attributes <= 4, `rooted insertion rewrote ${rooted.attributes} attributes`)
    assert.ok(
      rooted.attributeTargets <= 2,
      `rooted insertion rewrote ${rooted.attributeTargets} elements`
    )

    assert.ok(
      baseline.mutationTargets >= 100,
      `unrooted baseline unexpectedly touched only ${baseline.mutationTargets} targets: ${JSON.stringify(
        baseline
      )}`
    )
    assert.ok(
      baseline.attributes >= 400,
      `unrooted baseline unexpectedly produced only ${baseline.attributes} attribute mutations`
    )
    assert.ok(
      rooted.mutationTargets * 20 < baseline.mutationTargets,
      `patch breadth did not collapse: ${baseline.mutationTargets} -> ${rooted.mutationTargets}`
    )

    console.log(
      "patch-breadth metrics " +
        JSON.stringify({
          baseline,
          rooted
        })
    )
  } finally {
    await new Promise(resolve => server.close(resolve))
  }
})

const ROW_MAGIC_IDS = 120
