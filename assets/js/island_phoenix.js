export function createPhoenixIslandBinding() {
  const hooksByRoot = new WeakMap()
  let lifecycle

  const hooks = {
    AshUiIsland: {
      mounted() {
        hooksByRoot.set(this.el, this)
        return lifecycle?.onAttach(this.el)
      },
      updated() {
        return lifecycle?.onSync(this.el)
      },
      destroyed() {
        const result = lifecycle?.onDetach(this.el, "terminal")
        hooksByRoot.delete(this.el)
        return result
      },
      disconnected() {
        return lifecycle?.onSuspend(this.el)
      },
      reconnected() {
        return lifecycle?.onResume(this.el)
      }
    }
  }

  return {
    hooks,
    observe(callbacks) {
      lifecycle = callbacks
      return () => {
        lifecycle = undefined
      }
    },
    send(root, binding, payload) {
      const hook = hooksByRoot.get(root)

      if (!hook || typeof hook.pushEvent !== "function") {
        throw new Error("AshUi island root is not mounted in LiveView")
      }

      return hook.pushEvent("ash_ui:dispatch", {...payload, binding})
    }
  }
}
