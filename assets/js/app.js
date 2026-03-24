import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import TimezoneDetect from "./hooks/timezone_detect"

// SaladUI — import all component JS so any component works without extra setup
import SaladUILib from "salad_ui"
import "salad_ui/components/accordion"
// chart requires chart.js npm package — skip until needed
// import "salad_ui/components/chart"
import "salad_ui/components/collapsible"
import "salad_ui/components/command"
import "salad_ui/components/dialog"
import "salad_ui/components/dropdown_menu"
import "salad_ui/components/hover-card"
import "salad_ui/components/menu"
import "salad_ui/components/popover"
import "salad_ui/components/radio_group"
import "salad_ui/components/select"
import "salad_ui/components/slider"
import "salad_ui/components/switch"
import "salad_ui/components/tabs"
import "salad_ui/components/tooltip"

let Hooks = {}
Hooks.TimezoneDetect = TimezoneDetect
Hooks.SaladUI = SaladUILib.SaladUIHook

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
