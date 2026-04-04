/**
 * WorkflowEditor hook — handles:
 * 1. Drag-and-drop node repositioning (with live edge redraw)
 * 2. Drag-to-connect: output port → input port edge creation
 * 3. Edge rendering from real DOM port positions (no server-side guessing)
 * 4. Click-to-delete edges
 */
const WorkflowEditor = {
  mounted() {
    this.dragging = null
    this.offset = { x: 0, y: 0 }
    this.connecting = null
    this.tempLine = document.getElementById('temp-edge')
    this.edgeGroup = document.getElementById('edge-group')

    // Draw edges after mount
    requestAnimationFrame(() => this.drawEdges())

    // --- Node dragging ---
    this.el.addEventListener("mousedown", (e) => {
      if (e.target.closest("[data-port-out]") || e.target.closest("[data-port-in]")) return
      const nodeEl = e.target.closest("[data-node-id]")
      if (!nodeEl) return

      e.preventDefault()
      const rect = nodeEl.getBoundingClientRect()
      this.dragging = nodeEl
      this.offset = { x: e.clientX - rect.left, y: e.clientY - rect.top }
      nodeEl.style.zIndex = "10"
    })

    // --- Port connection: start from output port ---
    this.el.addEventListener("mousedown", (e) => {
      const portEl = e.target.closest("[data-port-out]")
      if (!portEl) return

      e.preventDefault()
      e.stopPropagation()

      const nodeId = portEl.getAttribute("data-port-out")
      const portName = portEl.getAttribute("data-port-name") || "output"
      const pos = this.portCenter(portEl)

      this.connecting = { sourceNodeId: nodeId, sourcePort: portName, startX: pos.x, startY: pos.y }

      if (this.tempLine) {
        this.tempLine.setAttribute("x1", pos.x)
        this.tempLine.setAttribute("y1", pos.y)
        this.tempLine.setAttribute("x2", pos.x)
        this.tempLine.setAttribute("y2", pos.y)
        this.tempLine.classList.remove("hidden")
      }
    })

    // --- Mouse move ---
    this._onMouseMove = (e) => {
      const canvasRect = this.el.getBoundingClientRect()

      // Node dragging — move node AND redraw edges live
      if (this.dragging) {
        const x = Math.max(0, Math.round(e.clientX - canvasRect.left - this.offset.x + this.el.scrollLeft))
        const y = Math.max(0, Math.round(e.clientY - canvasRect.top - this.offset.y + this.el.scrollTop))
        this.dragging.parentElement.style.left = `${x}px`
        this.dragging.parentElement.style.top = `${y}px`
        this.drawEdges()
      }

      // Connection dragging — update temp line
      if (this.connecting && this.tempLine) {
        const x = e.clientX - canvasRect.left + this.el.scrollLeft
        const y = e.clientY - canvasRect.top + this.el.scrollTop
        this.tempLine.setAttribute("x2", x)
        this.tempLine.setAttribute("y2", y)

        // Highlight input ports on hover
        document.querySelectorAll("[data-port-in]").forEach(p => {
          p.classList.remove("ring-2", "ring-indigo-400")
        })
        const target = document.elementFromPoint(e.clientX, e.clientY)
        const portIn = target?.closest("[data-port-in]")
        if (portIn && portIn.getAttribute("data-port-in") !== this.connecting.sourceNodeId) {
          portIn.classList.add("ring-2", "ring-indigo-400")
        }
      }
    }
    document.addEventListener("mousemove", this._onMouseMove)

    // --- Mouse up ---
    this._onMouseUp = (e) => {
      if (this.dragging) {
        const canvasRect = this.el.getBoundingClientRect()
        const x = Math.max(0, Math.round(e.clientX - canvasRect.left - this.offset.x + this.el.scrollLeft))
        const y = Math.max(0, Math.round(e.clientY - canvasRect.top - this.offset.y + this.el.scrollTop))
        const nodeId = this.dragging.getAttribute("data-node-id")
        this.dragging.style.zIndex = "2"
        this.dragging = null
        this.pushEvent("move_node", { id: nodeId, x, y })
      }

      if (this.connecting) {
        const target = document.elementFromPoint(e.clientX, e.clientY)
        const portIn = target?.closest("[data-port-in]")

        if (portIn) {
          const targetNodeId = portIn.getAttribute("data-port-in")
          if (targetNodeId !== this.connecting.sourceNodeId) {
            this.pushEvent("add_edge", {
              source: this.connecting.sourceNodeId,
              target: targetNodeId,
              source_port: this.connecting.sourcePort,
              target_port: "input"
            })
          }
        }

        if (this.tempLine) this.tempLine.classList.add("hidden")
        document.querySelectorAll("[data-port-in]").forEach(p => {
          p.classList.remove("ring-2", "ring-indigo-400")
        })
        this.connecting = null
      }
    }
    document.addEventListener("mouseup", this._onMouseUp)
  },

  destroyed() {
    document.removeEventListener("mousemove", this._onMouseMove)
    document.removeEventListener("mouseup", this._onMouseUp)
  },

  updated() {
    // Redraw edges whenever LiveView patches the DOM
    requestAnimationFrame(() => this.drawEdges())
  },

  /** Get center of a port element relative to the canvas */
  portCenter(portEl) {
    const portRect = portEl.getBoundingClientRect()
    const canvasRect = this.el.getBoundingClientRect()
    return {
      x: portRect.left + portRect.width / 2 - canvasRect.left + this.el.scrollLeft,
      y: portRect.top + portRect.height / 2 - canvasRect.top + this.el.scrollTop
    }
  },

  /** Find output port element for a given node + port name */
  findOutputPort(nodeId, portName) {
    return this.el.querySelector(
      `[data-port-out="${nodeId}"][data-port-name="${portName}"]`
    )
  },

  /** Find input port element for a given node */
  findInputPort(nodeId) {
    return this.el.querySelector(`[data-port-in="${nodeId}"]`)
  },

  /** Draw all edges by reading actual DOM port positions */
  drawEdges() {
    if (!this.edgeGroup) return
    let edges = []
    try {
      edges = JSON.parse(this.el.getAttribute("data-edges") || "[]")
    } catch (e) {
      console.error("WorkflowEditor: failed to parse edge data", e)
      return
    }
    const ns = "http://www.w3.org/2000/svg"

    // Clear existing
    this.edgeGroup.innerHTML = ""

    for (const edge of edges) {
      const outPort = this.findOutputPort(edge.source_node_id, edge.source_port)
      const inPort = this.findInputPort(edge.target_node_id)
      if (!outPort || !inPort) continue

      const from = this.portCenter(outPort)
      const to = this.portCenter(inPort)
      const midX = (from.x + to.x) / 2
      const d = `M ${from.x} ${from.y} C ${midX} ${from.y}, ${midX} ${to.y}, ${to.x} ${to.y}`

      const color = edge.source_port === "true" ? "#34d399"
                   : edge.source_port === "false" ? "#f87171"
                   : "#6b7280"

      // Group for hit area + visible path
      const g = document.createElementNS(ns, "g")
      g.style.cursor = "pointer"
      g.style.pointerEvents = "auto"
      g.setAttribute("data-edge-id", edge.id)

      // Invisible hit area
      const hit = document.createElementNS(ns, "path")
      hit.setAttribute("d", d)
      hit.setAttribute("fill", "none")
      hit.setAttribute("stroke", "transparent")
      hit.setAttribute("stroke-width", "14")
      g.appendChild(hit)

      // Visible line
      const path = document.createElementNS(ns, "path")
      path.setAttribute("d", d)
      path.setAttribute("fill", "none")
      path.setAttribute("stroke", color)
      path.setAttribute("stroke-width", "2")
      path.setAttribute("stroke-linecap", "round")
      g.appendChild(path)

      // Label for branch ports
      if (edge.source_port === "true" || edge.source_port === "false") {
        const text = document.createElementNS(ns, "text")
        text.setAttribute("x", from.x + 10)
        text.setAttribute("y", from.y - 6)
        text.setAttribute("fill", color)
        text.setAttribute("font-size", "10")
        text.style.pointerEvents = "none"
        text.style.userSelect = "none"
        text.textContent = edge.source_port
        g.appendChild(text)
      }

      // Click to delete
      g.addEventListener("click", (e) => {
        e.stopPropagation()
        this.pushEvent("delete_edge", { id: edge.id })
      })

      // Hover effect
      g.addEventListener("mouseenter", () => { path.setAttribute("stroke-width", "3") })
      g.addEventListener("mouseleave", () => { path.setAttribute("stroke-width", "2") })

      this.edgeGroup.appendChild(g)
    }
  }
}

export default WorkflowEditor
