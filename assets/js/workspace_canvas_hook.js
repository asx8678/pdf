// WorkspaceCanvasHook — composite hook for the document canvas.
//
// Phoenix LiveView 1.2.x resolves `phx-hook` as a SINGLE hook name — the
// previous `phx-hook="PdfViewerHook SnapshotHook ReadAloudHook DocMutateHook"`
// never mounted (every hook came back as "unknown hook"). All four canvas
// hooks need #pdf-viewer-container (or the .textLayer) as a descendant of
// their element, so they cannot live on separate siblings. This composite
// mounts them all on the one #document-canvas element.
//
// Each sub-hook keeps its own `this` (its methods call each other through
// the prototype chain) but is given the ViewHook surface the hooks rely
// on: el / handleEvent / pushEvent.

import PdfViewerHook from "./pdf_viewer_hook.js";
import SnapshotHook from "./snapshot_hook.js";
import ReadAloudHook from "./read_aloud_hook.js";
import DocMutateHook from "./doc_mutate_hook.js";

function bindSubHook(hook, viewHook) {
  return Object.assign(Object.create(hook), {
    el: viewHook.el,
    handleEvent: (event, callback) => viewHook.handleEvent(event, callback),
    pushEvent: (event, payload, onReply) => viewHook.pushEvent(event, payload, onReply),
  });
}

const WorkspaceCanvasHook = {
  mounted() {
    this._subs = [PdfViewerHook, SnapshotHook, ReadAloudHook, DocMutateHook].map((hook) => {
      const ctx = bindSubHook(hook, this);
      if (typeof hook.mounted === "function") hook.mounted.call(ctx);
      return ctx;
    });
  },

  destroyed() {
    (this._subs || [])
      .slice()
      .reverse()
      .forEach((ctx) => {
        const hook = Object.getPrototypeOf(ctx);
        if (typeof hook.destroyed === "function") hook.destroyed.call(ctx);
      });
  },
};

export default WorkspaceCanvasHook;
