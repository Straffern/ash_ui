import {createIslandRuntime} from "../../../../assets/js/island.js"
import {createDatastarIslandBinding} from "./island_datastar.js"

const runtime = createIslandRuntime({binding: createDatastarIslandBinding()})
const island = Object.freeze({define: runtime.define})
const AshUi = globalThis.AshUi || {}

AshUi.island = island
globalThis.AshUi = AshUi

export {island}
