import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let Hooks = {}

// Auto-scroll chat messages to bottom on update
Hooks.ScrollBottom = {
  mounted() {
    this.scrollToBottom()
  },
  updated() {
    if (this.isNearBottom()) {
      this.scrollToBottom()
    }
  },
  isNearBottom() {
    const threshold = 100
    return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < threshold
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

liveSocket.connect()

window.liveSocket = liveSocket
