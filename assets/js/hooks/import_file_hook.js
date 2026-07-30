// XFDF import file hook
//
// Listens for the "trigger_file_input" event pushed from the LiveView,
// opens a file picker, reads the selected .xfdf file as text, and
// pushes the content to the server for import.

const ImportFile = {
  mounted() {
    this.el.addEventListener("change", () => {
      const file = this.el.files && this.el.files[0];
      if (!file) return;

      const reader = new FileReader();
      reader.onload = (e) => {
        const content = e.target.result;
        this.pushEvent("import_xfdf", { file: content });
      };
      reader.readAsText(file);

      // Reset so the same file can be re-imported
      this.el.value = "";
    });

    this.handleTrigger = () => {
      this.el.click();
    };

    this.el.addEventListener("phx:trigger_file_input", this.handleTrigger);
  },

  destroyed() {
    this.el.removeEventListener("phx:trigger_file_input", this.handleTrigger);
  }
};

export default ImportFile;
