// T-121: drag to reorder the Forms-tab field list, then persist the new
// tab order to the server (rewrites the AcroForm /Fields array order).
const FieldListDrag = {
  mounted() {
    this.el.addEventListener("dragstart", (e) => {
      this._dragging = this.el.dataset.ref;
      e.dataTransfer.effectAllowed = "move";
      this.el.classList.add("opacity-50");
    });

    this.el.addEventListener("dragend", () => {
      this.el.classList.remove("opacity-50");
      this._dragging = null;
    });

    this.el.addEventListener("dragover", (e) => {
      e.preventDefault();
      const target = e.currentTarget;
      if (this._dragging === target.dataset.ref) return;
      // Move the dragged chip before/after based on pointer position.
      const rect = target.getBoundingClientRect();
      const before = e.clientY < rect.top + rect.height / 2;
      const dragged = document.querySelector(`[data-ref="${this._dragging}"]`);
      if (dragged && dragged !== target) {
        const list = target.parentNode;
        list.insertBefore(dragged, before ? target : target.nextSibling);
      }
    });

    this.el.addEventListener("drop", (e) => {
      e.preventDefault();
      this._commitOrder();
    });
  },

  _commitOrder() {
    const list = document.getElementById("form-field-list");
    if (!list) return;
    // The li order now reflects the desired tab order. Send the refs in order
    // so the server can rewrite /Fields. refs are the li data-ref indices.
    const refs = [...list.querySelectorAll("li[data-ref]")].map((li) => li.dataset.ref);
    this.pushEvent("reorder_form_fields", { refs });
  },
};

export default FieldListDrag;
