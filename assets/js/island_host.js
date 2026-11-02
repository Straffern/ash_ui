// The host affordances an adapter hands the island runtime (`island.js` `hostAffordances/1`).
//
//   * `browserIslandHost(document)` — a page in an ordinary tab: a download is an anchor with a
//     `download` name over the file's bytes; there is no conversation, so no message or model
//     context.

export function browserIslandHost(document) {
  return {
    capabilities: {downloadFile: true},
    downloadFile({contents = []} = {}) {
      let downloaded = false
      for (const content of contents) {
        const resource = content?.resource
        if (!resource) continue
        const bytes = resource.blob === undefined
          ? new TextEncoder().encode(String(resource.text ?? ""))
          : Uint8Array.from(atob(resource.blob), (character) => character.charCodeAt(0))
        const url = URL.createObjectURL(new Blob([bytes], {type: resource.mimeType || "application/octet-stream"}))
        const anchor = document.createElement("a")
        anchor.href = url
        anchor.download = downloadName(resource.uri)
        anchor.rel = "noopener"
        document.body.appendChild(anchor)
        anchor.click()
        anchor.remove()
        // The browser may still be reading the URL after `click()` returns; FileSaver waits 40 s.
        setTimeout(() => URL.revokeObjectURL(url), REVOKE_AFTER_MS)
        downloaded = true
      }
      // Nothing downloadable was offered: the request failed, as `ui/download-file` reports it.
      return downloaded ? {} : {isError: true}
    }
  }
}

const REVOKE_AFTER_MS = 40000

// The file's name: the last segment of its URI, decoded when it is well-formed percent-encoding.
function downloadName(uri) {
  const segment = String(uri ?? "download").split("/").pop() || "download"
  try {
    return decodeURIComponent(segment)
  } catch {
    return segment
  }
}
