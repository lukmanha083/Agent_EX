/**
 * Sortable hook for drag-and-drop reordering of intervention pipeline handlers.
 *
 * Uses event delegation on the stable container (no per-element listeners).
 * Pushes "reorder_pipeline" event with the new order of handler IDs.
 */
const Sortable = {
  mounted() {
    this.draggedId = null

    this.el.addEventListener("dragstart", (e) => {
      const item = e.target.closest("[data-id]")
      if (!item) return
      this.draggedId = item.dataset.id
      e.dataTransfer.effectAllowed = "move"
      e.dataTransfer.setData("text/plain", this.draggedId)
      item.classList.add("opacity-50")
    })

    this.el.addEventListener("dragend", (e) => {
      const item = e.target.closest("[data-id]")
      if (item) item.classList.remove("opacity-50")
      this.el
        .querySelectorAll("[data-id]")
        .forEach((el) => el.classList.remove("border-indigo-500"))
      this.draggedId = null
    })

    this.el.addEventListener("dragover", (e) => {
      const item = e.target.closest("[data-id]")
      if (!item) return
      e.preventDefault()
      e.dataTransfer.dropEffect = "move"
      item.classList.add("border-indigo-500")
    })

    this.el.addEventListener("dragleave", (e) => {
      const item = e.target.closest("[data-id]")
      if (item) item.classList.remove("border-indigo-500")
    })

    this.el.addEventListener("drop", (e) => {
      const item = e.target.closest("[data-id]")
      if (!item) return
      e.preventDefault()
      item.classList.remove("border-indigo-500")

      const draggedId = e.dataTransfer.getData("text/plain")
      const targetId = item.dataset.id

      if (draggedId && draggedId !== targetId) {
        const ids = Array.from(this.el.querySelectorAll("[data-id]")).map(
          (el) => el.dataset.id
        )
        const fromIdx = ids.indexOf(draggedId)
        const toIdx = ids.indexOf(targetId)

        if (fromIdx === -1 || toIdx === -1) return

        ids.splice(fromIdx, 1)
        ids.splice(toIdx, 0, draggedId)

        this.pushEvent("reorder_pipeline", { ids })
      }
    })

    this.ensureDraggable()
  },

  updated() {
    this.ensureDraggable()
  },

  ensureDraggable() {
    this.el.querySelectorAll("[data-id]").forEach((item) => {
      item.setAttribute("draggable", "true")
    })
  },
}

export default Sortable
