// TextFormatBar — T-090 Floating text format bar
//
// A floating toolbar positioned above the selected FreeText editor.
// Appended to the pdf-viewer-wrapper and managed entirely in the DOM.
// All style changes are forwarded via onStyleChange callback.
//
// Style: floating bar with rounded corners, shadow, light/dark support.

// Standard font families commonly used in PDF
const FONT_FAMILIES = [
  "Helvetica",
  "Times New Roman",
  "Courier",
  "Arial",
  "Georgia",
  "Verdana",
  "Trebuchet MS",
  "Comic Sans MS",
  "Impact",
  "Palatino Linotype",
];

// Font sizes 8–72 in 1pt increments (only common values listed)
const FONT_SIZES = Array.from({ length: 65 }, (_, i) => i + 8);

// Alignment options
const ALIGNMENTS = [
  { value: "left",   label: "Left",   icon: "left" },
  { value: "center", label: "Center", icon: "center" },
  { value: "right",  label: "Right",  icon: "right" },
  { value: "justify",label: "Justify",icon: "justify" },
];

export class TextFormatBar {
  /**
   * @param {object} opts
   * @param {HTMLElement} opts.container - Element to append the bar to
   * @param {object} [opts.eventBus] - pdf.js eventBus (optional, for dispatch)
   * @param {function} opts.onStyleChange - (type: string, value: any) => void
   */
  constructor(opts = {}) {
    this.container = opts.container || document.body;
    this.eventBus = opts.eventBus || null;
    this.onStyleChange = opts.onStyleChange || (() => {});
    this._el = null;
    this._visible = false;
    this._ignoreInput = false;
  }

  /**
   * Show the format bar above (or below) the given bounding rect.
   * @param {DOMRect} editorRect - Bounding rect of the editor element
   * @param {object} [styles] - Initial style values
   */
  show(editorRect, styles = {}) {
    if (!this._el) this._render();
    this._visible = true;
    this._updateControls(styles);
    // Temporarily reveal to measure dimensions for positioning
    this._el.classList.remove("hidden");
    this._position(editorRect);
  }

  /**
   * Hide the format bar.
   */
  hide() {
    if (!this._el || !this._visible) return;
    this._visible = false;
    this._el.classList.add("hidden");
  }

  /**
   * Update the controls to reflect current editor styles without moving.
   * @param {object} styles
   */
  updateStyles(styles) {
    if (!this._el || !this._visible) return;
    this._updateControls(styles);
  }

  /** Create the bar DOM — call once. */
  _render() {
    this._el = document.createElement("div");
    this._el.className =
      "text-format-bar hidden fixed z-[100] flex flex-col rounded-lg border " +
      "border-gray-200 dark:border-gray-600 bg-white dark:bg-gray-800 " +
      "shadow-xl text-xs select-none";
    this._el.setAttribute("role", "toolbar");
    this._el.setAttribute("aria-label", "Text formatting");
    this._el.style.minWidth = "420px";

    // --- Row 1: font controls, decoration, color ---
    const row1 = document.createElement("div");
    row1.className = "flex items-center gap-1 px-2 pt-1.5 pb-1 border-b border-gray-100 dark:border-gray-700 flex-wrap";

    // Font family
    row1.appendChild(this._makeLabel("Font"));
    const familySelect = this._makeSelect(FONT_FAMILIES, "font-family", "Helvetica");
    familySelect.addEventListener("change", () => {
      this._fire("fontFamily", familySelect.value);
    });
    this._familySelect = familySelect;
    row1.appendChild(familySelect);

    // Font size
    row1.appendChild(this._makeLabel("Size", "ml-1"));
    const sizeSelect = this._makeSelect(FONT_SIZES, "font-size", "12");
    sizeSelect.addEventListener("change", () => {
      this._fire("fontSize", parseInt(sizeSelect.value, 10));
    });
    this._sizeSelect = sizeSelect;
    row1.appendChild(sizeSelect);

    // Separator
    row1.appendChild(this._sep());

    // Bold
    this._boldBtn = this._toggleBtn("B", "bold", () => {
      this._fire("bold", this._boldBtn.classList.contains("active"));
    });
    this._boldBtn.style.fontWeight = "700";
    this._boldBtn.title = "Bold";
    row1.appendChild(this._boldBtn);

    // Italic
    this._italicBtn = this._toggleBtn("I", "italic", () => {
      this._fire("italic", this._italicBtn.classList.contains("active"));
    });
    this._italicBtn.style.fontStyle = "italic";
    this._italicBtn.title = "Italic";
    row1.appendChild(this._italicBtn);

    // Separator
    row1.appendChild(this._sep());

    // Font colour picker
    this._colorInput = this._colorPicker("#font-color", "Text colour");
    this._colorInput.addEventListener("input", () => {
      this._fire("fontColor", this._colorInput.value);
    });
    row1.appendChild(this._colorInput._wrap);

    // Highlight colour picker
    this._hlInput = this._colorPicker("#highlight-color", "Highlight colour");
    this._hlInput.addEventListener("input", () => {
      this._fire("highlightColor", this._hlInput.value);
    });
    row1.appendChild(this._hlInput._wrap);

    // Separator
    row1.appendChild(this._sep());

    // Strikethrough
    this._strikeBtn = this._toggleBtn("S", "strikethrough", () => {
      this._fire("strikethrough", this._strikeBtn.classList.contains("active"));
    });
    this._strikeBtn.title = "Strikethrough";
    this._strikeBtn.style.textDecoration = "line-through";
    row1.appendChild(this._strikeBtn);

    // Underline
    this._underlineBtn = this._toggleBtn("U", "underline", () => {
      this._fire("underline", this._underlineBtn.classList.contains("active"));
    });
    this._underlineBtn.title = "Underline";
    this._underlineBtn.style.textDecoration = "underline";
    row1.appendChild(this._underlineBtn);

    this._el.appendChild(row1);

    // --- Row 2: alignment, indent, link, overflow ---
    const row2 = document.createElement("div");
    row2.className = "flex items-center gap-1 px-2 pb-1.5 pt-1 flex-wrap";

    // Alignment dropdown
    row2.appendChild(this._makeLabel("Align", "mr-0.5"));
    this._alignSelect = document.createElement("select");
    this._alignSelect.className =
      "text-xs border border-gray-200 dark:border-gray-600 rounded " +
      "bg-transparent px-1 py-0.5 outline-none cursor-pointer " +
      "text-gray-700 dark:text-gray-200";
    this._alignSelect.title = "Alignment";
    ALIGNMENTS.forEach(a => {
      const opt = document.createElement("option");
      opt.value = a.value;
      opt.textContent = a.label;
      this._alignSelect.appendChild(opt);
    });
    this._alignSelect.addEventListener("change", () => {
      this._fire("alignment", this._alignSelect.value);
    });
    row2.appendChild(this._alignSelect);

    // Separator
    row2.appendChild(this._sep());

    // Decrease indent
    this._outdentBtn = this._actionBtn(
      this._svgIcon("M4 12h16M8 8l-4 4 4 4", "Decrease indent"),
      "outdent",
      () => this._fire("indent", -1)
    );
    row2.appendChild(this._outdentBtn);

    // Increase indent
    this._indentBtn = this._actionBtn(
      this._svgIcon("M20 12H4m12-4l4 4-4 4", "Increase indent"),
      "indent",
      () => this._fire("indent", 1)
    );
    row2.appendChild(this._indentBtn);

    // Separator
    row2.appendChild(this._sep());

    // Anchor / Link button
    this._linkBtn = this._actionBtn(
      this._svgIcon(
        "M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.102m3.302-3.302a4 4 0 015.656 0l4 4a4 4 0 01-5.656 5.656l-1.102-1.102",
        "Link"
      ),
      "link",
      () => this._fire("link", null)
    );
    row2.appendChild(this._linkBtn);

    // Separator
    row2.appendChild(this._sep());

    // Overflow menu (chevron)
    this._overflowBtn = this._actionBtn(
      this._svgIcon("M12 5v.01M12 12v.01M12 19v.01", "More options"),
      "overflow",
      () => this._toggleOverflow()
    );
    row2.appendChild(this._overflowBtn);

    // Overflow dropdown (hidden initially)
    this._overflowMenu = document.createElement("div");
    this._overflowMenu.className =
      "hidden absolute top-full right-0 mt-1 z-50 rounded-lg border " +
      "border-gray-200 dark:border-gray-600 bg-white dark:bg-gray-800 " +
      "shadow-lg py-1 min-w-[140px]";
    this._overflowMenu.setAttribute("role", "menu");
    this._buildOverflowMenu();
    this._overflowBtn.style.position = "relative";
    this._overflowBtn.appendChild(this._overflowMenu);

    // Close button
    row2.appendChild(this._sep());
    const closeBtn = document.createElement("button");
    closeBtn.type = "button";
    closeBtn.className =
      "flex items-center justify-center w-5 h-5 rounded " +
      "hover:bg-gray-100 dark:hover:bg-gray-700 text-gray-400 " +
      "hover:text-gray-600 dark:hover:text-gray-300 transition-colors cursor-pointer ml-auto";
    closeBtn.title = "Close";
    closeBtn.innerHTML = this._svgIcon("M6 18L18 6M6 6l12 12", "Close");
    closeBtn.addEventListener("click", () => this._fire("close", null));
    row2.appendChild(closeBtn);

    this._el.appendChild(row2);

    this.container.appendChild(this._el);
  }

  /** Position the bar relative to editorRect. */
  _position(editorRect) {
    if (!this._el) return;
    const barHeight = this._el.offsetHeight || 48;
    const gap = 8;
    const ribbonBottom = 120; // ~120px for title + menu + ribbon
    const viewportH = window.innerHeight;
    let top;

    // Prefer above
    const aboveY = editorRect.top - barHeight - gap;
    if (aboveY >= ribbonBottom) {
      top = aboveY;
    } else {
      // Below (if room)
      const belowY = editorRect.bottom + gap;
      if (belowY + barHeight <= viewportH) {
        top = belowY;
      } else {
        // No room either side — clamp to ribbon bottom
        top = Math.max(ribbonBottom, viewportH - barHeight - gap);
      }
    }

    // Centre horizontally over the editor, clamped to viewport
    const barWidth = this._el.offsetWidth || 420;
    let left = editorRect.left + editorRect.width / 2 - barWidth / 2;
    left = Math.max(8, Math.min(left, window.innerWidth - barWidth - 8));

    this._el.style.top = `${top}px`;
    this._el.style.left = `${left}px`;
  }

  /** Update control states from current editor style values. */
  _updateControls(styles) {
    if (!this._el) return;
    this._ignoreInput = true;

    if (styles.fontFamily && this._familySelect) {
      this._familySelect.value = styles.fontFamily;
    }
    if (styles.fontSize && this._sizeSelect) {
      this._sizeSelect.value = String(styles.fontSize);
    }
    if (this._boldBtn) {
      this._boldBtn.classList.toggle("active", !!styles.bold);
    }
    if (this._italicBtn) {
      this._italicBtn.classList.toggle("active", !!styles.italic);
    }
    if (this._underlineBtn) {
      this._underlineBtn.classList.toggle("active", !!styles.underline);
    }
    if (this._strikeBtn) {
      this._strikeBtn.classList.toggle("active", !!styles.strikethrough);
    }
    if (styles.fontColor && this._colorInput) {
      this._colorInput.value = styles.fontColor;
    }
    if (styles.highlightColor && this._hlInput) {
      this._hlInput.value = styles.highlightColor;
    }
    if (styles.alignment && this._alignSelect) {
      this._alignSelect.value = styles.alignment;
    }

    this._ignoreInput = false;
  }

  // --- Internal helpers ---

  _fire(type, value) {
    if (this._ignoreInput) return;
    this.onStyleChange(type, value);
  }

  _makeLabel(text, extra = "") {
    const lbl = document.createElement("span");
    lbl.className = `text-[10px] text-gray-400 dark:text-gray-500 uppercase tracking-wide ${extra}`;
    lbl.textContent = text;
    return lbl;
  }

  _makeSelect(values, id, defaultValue) {
    const sel = document.createElement("select");
    sel.className =
      "text-xs border border-gray-200 dark:border-gray-600 rounded " +
      "bg-transparent px-1 py-0.5 outline-none cursor-pointer " +
      "text-gray-700 dark:text-gray-200 max-w-[100px]";
    sel.id = id;
    values.forEach(v => {
      const opt = document.createElement("option");
      opt.value = String(v);
      opt.textContent = String(v);
      sel.appendChild(opt);
    });
    sel.value = String(defaultValue);
    return sel;
  }

  _toggleBtn(label, name, onClick) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className =
      "flex items-center justify-center w-6 h-6 rounded text-xs font-medium " +
      "text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 " +
      "transition-colors cursor-pointer active:bg-gray-200 dark:active:bg-gray-600 " +
      "data-[active]:bg-gray-200 dark:data-[active]:bg-gray-600";
    btn.textContent = label;
    btn.addEventListener("click", () => {
      btn.classList.toggle("active");
      onClick();
    });
    return btn;
  }

  _actionBtn(innerHtml, name, onClick) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className =
      "flex items-center justify-center w-6 h-6 rounded " +
      "text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 " +
      "transition-colors cursor-pointer";
    btn.innerHTML = innerHtml;
    btn.title = name;
    btn.addEventListener("click", onClick);
    return btn;
  }

  _colorPicker(id, title) {
    const wrap = document.createElement("span");
    wrap.className = "relative inline-flex items-center";
    const input = document.createElement("input");
    input.type = "color";
    input.id = id;
    input.title = title;
    input.className =
      "w-5 h-5 p-0 border border-gray-200 dark:border-gray-600 rounded cursor-pointer " +
      "bg-transparent";
    input.value = "#000000";
    // Hide the default color well's white border by making it a block
    input.style.appearance = "none";
    input.style.webkitAppearance = "none";
    input.style.border = "none";
    input.style.padding = "0";
    wrap.appendChild(input);
    // Store reference for cleanup
    input._wrap = wrap;
    return input;
  }

  _svgIcon(pathData, label) {
    return `<svg xmlns="http://www.w3.org/2000/svg" class="w-3.5 h-3.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-label="${label}"><path d="${pathData}"/></svg>`;
  }

  _sep() {
    const el = document.createElement("span");
    el.className = "w-px h-5 bg-gray-200 dark:bg-gray-600 mx-0.5";
    return el;
  }

  _buildOverflowMenu() {
    const items = [
      { label: "Line spacing",   type: "lineSpacing" },
      { label: "Character spacing", type: "charSpacing" },
      { label: "Superscript",    type: "superscript" },
      { label: "Subscript",      type: "subscript" },
      { label: "Case",           type: "case" },
    ];
    items.forEach(item => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className =
        "w-full text-left px-3 py-1.5 text-xs text-gray-600 dark:text-gray-300 " +
        "hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors cursor-pointer";
      btn.textContent = item.label;
      btn.addEventListener("click", (e) => {
        e.stopPropagation();
        this._hideOverflow();
        this._fire(item.type, null);
      });
      this._overflowMenu.appendChild(btn);
    });
  }

  _toggleOverflow() {
    if (this._overflowMenu.classList.contains("hidden")) {
      this._overflowMenu.classList.remove("hidden");
      // Close on next click outside
      const closer = (e) => {
        if (!this._overflowMenu.contains(e.target) && e.target !== this._overflowBtn) {
          this._hideOverflow();
          document.removeEventListener("pointerdown", closer, true);
        }
      };
      document.addEventListener("pointerdown", closer, true);
    } else {
      this._hideOverflow();
    }
  }

  _hideOverflow() {
    this._overflowMenu.classList.add("hidden");
  }


}
