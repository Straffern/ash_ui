import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const sources = ["boot.js", "client.js", "island.js", "island_host.js", "island_phoenix.js"].sort();
const hash = createHash("sha256");

for (const source of sources) {
  hash.update(readFileSync(resolve(here, source)));
}

writeFileSync(
  resolve(here, "../../packages/ash_ui_phoenix/priv/static/ash_ui.min.js.sources.sha256"),
  `${hash.digest("hex")}\n`
);
