// doc_mutate_hook.js — T-088
// LiveView hook for client-side document mutations via @cantoo/pdf-lib.
// Applies mutations optimistically, maintains inverse bytes for revert,
// and pushes ops to the server. The Save flow reuses the existing
// document_saved handler from pdf-7ov.

import * as mutate from "./mutate.js";

const DocMutateHook = {
  mounted() {
    /** @type {Uint8Array|null} Bytes before the last mutation (inverse). */
    this.priorBytes = null;

    // Load document bytes into pdf-lib on server request
    this.handleEvent("load_bytes", async ({ bytes }) => {
      try {
        const binary = atob(bytes);
        const uint8 = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) {
          uint8[i] = binary.charCodeAt(i);
        }
        await mutate.load(uint8);
        this.pushEvent("bytes_loaded", {});
      } catch (err) {
        this.pushEvent("mutation_error", { reason: err.message });
      }
    });

    // Apply a mutation: save inverse first, mutate, push result
    this.handleEvent("apply_mutation", async ({ kind, data }) => {
      try {
        // Capture inverse before mutating
        const before = mutate.getBytes();
        this.priorBytes = before ? new Uint8Array(before) : null;

        await mutate.applyMutation(async (doc) => {
          switch (kind) {
            case "page.add":
              doc.addPage();
              break;

            case "page.remove":
              if (data?.pageIndex != null) {
                doc.removePage(data.pageIndex);
              }
              break;

            case "page.rotate":
              if (data?.pageIndex != null && data?.rotation != null) {
                const page = doc.getPage(data.pageIndex);
                page.setRotation({ angle: data.rotation });
              }
              break;

            case "page.move":
              if (data?.fromIndex != null && data?.toIndex != null) {
                const pages = doc.getPages();
                const [page] = pages.splice(data.fromIndex, 1);
                pages.splice(data.toIndex, 0, page);
              }
              break;

            case "text.add":
              // FreeText annotations are handled by pdf.js's saveDocument;
              // no pdf-lib modification needed. The serialized editor data
              // is embedded in the PDF bytes when the user saves.
              break;

            default:
              throw new Error(`Unknown mutation kind: ${kind}`);
          }
        });

        const newBytes = mutate.getBytes();
        const encode = (arr) =>
          btoa(String.fromCharCode(...new Uint8Array(arr)));

        this.pushEvent("document_mutated", {
          kind,
          data,
          inverse_bytes: this.priorBytes ? encode(this.priorBytes) : null,
          bytes: encode(newBytes),
        });
      } catch (err) {
        this.pushEvent("mutation_error", { reason: err.message });
      }
    });

    // Reject a mutation: restore prior bytes
    this.handleEvent("reject_mutation", async () => {
      if (this.priorBytes) {
        try {
          await mutate.load(this.priorBytes);
          this.priorBytes = null;
        } catch (err) {
          this.pushEvent("mutation_error", { reason: err.message });
        }
      }
    });

    // Save current bytes via existing document_saved handler
    this.handleEvent("save_document", async () => {
      const bytes = mutate.getBytes();
      if (!bytes) return;
      const base64 = btoa(String.fromCharCode(...new Uint8Array(bytes)));
      this.pushEvent("document_saved", {
        bytes: base64,
        byte_size: bytes.length,
      });
    });

    // Close: reset state
    this.handleEvent("close_mutate", () => {
      mutate.reset();
      this.priorBytes = null;
    });
  },

  destroyed() {
    this.priorBytes = null;
    mutate.reset();
  },
};

export default DocMutateHook;
