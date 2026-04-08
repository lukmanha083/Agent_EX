/**
 * AgentTree hook — auto-scrolls to the active agent node.
 */
const AgentTree = {
  mounted() {
    this._lastActiveNodeId = null
    this.scrollToActive()
  },

  updated() {
    this.scrollToActive()
  },

  scrollToActive() {
    const pulsingElements = this.el.querySelectorAll('.animate-pulse')
    if (pulsingElements.length === 0) return

    const lastPulsing = pulsingElements[pulsingElements.length - 1]
    const node = lastPulsing.closest('[id^="agent-node-"]')
    if (node && node.id !== this._lastActiveNodeId) {
      this._lastActiveNodeId = node.id
      node.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
    }
  }
}

export default AgentTree
