/**
 * Sortable hook for drag-and-drop reordering of intervention pipeline handlers.
 *
 * Uses the native HTML Drag and Drop API (no external deps).
 * Pushes "reorder_pipeline" event with the new order of handler IDs.
 */
const Sortable = {
  mounted() {
    this.setupDragHandlers()
  },

  updated() {
    this.setupDragHandlers()
  },

  setupDragHandlers() {
    const items = this.el.querySelectorAll("[data-id]")

    items.forEach((item) => {
      item.setAttribute("draggable", "true")

      item.addEventListener("dragstart", (e) => {
        e.dataTransfer.effectAllowed = "move"
        e.dataTransfer.setData("text/plain", item.dataset.id)
        item.classList.add("opacity-50")
      })

      item.addEventListener("dragend", () => {
        item.classList.remove("opacity-50")
        this.el
          .querySelectorAll("[data-id]")
          .forEach((el) => el.classList.remove("border-indigo-500"))
      })

      item.addEventListener("dragover", (e) => {
        e.preventDefault()
        e.dataTransfer.dropEffect = "move"
        item.classList.add("border-indigo-500")
      })

      item.addEventListener("dragleave", () => {
        item.classList.remove("border-indigo-500")
      })

      item.addEventListener("drop", (e) => {
        e.preventDefault()
        item.classList.remove("border-indigo-500")

        const draggedId = e.dataTransfer.getData("text/plain")
        const targetId = item.dataset.id

        if (draggedId !== targetId) {
          const ids = Array.from(this.el.querySelectorAll("[data-id]")).map(
            (el) => el.dataset.id
          )
          const fromIdx = ids.indexOf(draggedId)
          const toIdx = ids.indexOf(targetId)

          // Reorder
          ids.splice(fromIdx, 1)
          ids.splice(toIdx, 0, draggedId)

          this.pushEvent("reorder_pipeline", { ids })
        }
      })
    })
  },
}

export default Sortable
