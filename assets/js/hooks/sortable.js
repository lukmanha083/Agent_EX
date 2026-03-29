/**
 * Sortable hook for drag-and-drop reordering of intervention pipeline handlers.
 *
 * Uses the native HTML Drag and Drop API (no external deps).
 * Pushes "reorder_pipeline" event with the new order of handler IDs.
 */
const Sortable = {
  mounted() {
    this._handleDragStart = this._handleDragStart.bind(this)
    this._handleDragEnd = this._handleDragEnd.bind(this)
    this._handleDragOver = this._handleDragOver.bind(this)
    this._handleDragLeave = this._handleDragLeave.bind(this)
    this._handleDrop = this._handleDrop.bind(this)

    this.el.addEventListener("dragstart", this._handleDragStart)
    this.el.addEventListener("dragend", this._handleDragEnd)
    this.el.addEventListener("dragover", this._handleDragOver)
    this.el.addEventListener("dragleave", this._handleDragLeave)
    this.el.addEventListener("drop", this._handleDrop)

    this._markItemsDraggable()
  },

  updated() {
    this._markItemsDraggable()
  },

  destroyed() {
    this.el.removeEventListener("dragstart", this._handleDragStart)
    this.el.removeEventListener("dragend", this._handleDragEnd)
    this.el.removeEventListener("dragover", this._handleDragOver)
    this.el.removeEventListener("dragleave", this._handleDragLeave)
    this.el.removeEventListener("drop", this._handleDrop)
  },

  _markItemsDraggable() {
    this.el.querySelectorAll("[data-id]").forEach((item) => {
      item.setAttribute("draggable", "true")
    })
  },

  _getItemFromEvent(e) {
    return e.target.closest("[data-id]")
  },

  _handleDragStart(e) {
    const item = this._getItemFromEvent(e)
    if (!item) return
    e.dataTransfer.effectAllowed = "move"
    e.dataTransfer.setData("text/plain", item.dataset.id)
    item.classList.add("opacity-50")
  },

  _handleDragEnd() {
    this.el
      .querySelectorAll("[data-id]")
      .forEach((el) => {
        el.classList.remove("opacity-50")
        el.classList.remove("border-indigo-500")
      })
  },

  _handleDragOver(e) {
    const item = this._getItemFromEvent(e)
    if (!item) return
    e.preventDefault()
    e.dataTransfer.dropEffect = "move"
    item.classList.add("border-indigo-500")
  },

  _handleDragLeave(e) {
    const item = this._getItemFromEvent(e)
    if (!item) return
    item.classList.remove("border-indigo-500")
  },

  _handleDrop(e) {
    const item = this._getItemFromEvent(e)
    if (!item) return
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

      ids.splice(fromIdx, 1)
      ids.splice(toIdx, 0, draggedId)

      this.pushEvent("reorder_pipeline", { ids })
    }
  },
}

export default Sortable
