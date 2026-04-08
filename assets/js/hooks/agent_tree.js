/**
 * AgentTree hook — auto-scrolls to the active agent node.
 */
const AgentTree = {
  mounted() {
    this.scrollToActive()
  },

  updated() {
    this.scrollToActive()
  },

  scrollToActive() {
    // Find the first node with a pulsing dot (running/thinking)
    const active = this.el.querySelector('.animate-pulse')
    if (active) {
      const node = active.closest('[id^="agent-node-"]')
      if (node) {
        node.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
      }
    }
  }
}

export default AgentTree
