// ReadAloudHook — T-056
//
// Drives the Web Speech API to read document text aloud with word
// highlighting. Handles play/pause/stop from server push_events and
// degrades gracefully when the API is unavailable.

const ReadAloudHook = {
  mounted() {
    this.synth = window.speechSynthesis;
    this.utterance = null;
    this.text = "";

    if (!this.synth) {
      this.el.setAttribute("data-unavailable", "true");
      return;
    }

    this.handleEvent("read_aloud", (data) => {
      if (data.text) this.text = data.text;

      switch (data.action) {
        case "play":
          this.play(data.page);
          break;
        case "pause":
          this.pause();
          break;
        case "stop":
          this.stop();
          break;
      }
    });
  },

  play(_page) {
    if (!this.synth) return;

    // Get text from the pdf.js text layer
    const textLayer = this.el.querySelector(".textLayer");
    if (!textLayer) return;

    this.text = textLayer.textContent || "";
    if (!this.text.trim()) return;

    this.synth.cancel();

    this.utterance = new SpeechSynthesisUtterance(this.text);
    this.utterance.rate = 0.9;
    this.utterance.pitch = 1.0;

    let wordIndex = 0;
    const words = this.text.split(/\s+/);

    this.utterance.onboundary = (event) => {
      if (event.name === "word") {
        this.highlightWord(wordIndex, words);
        wordIndex++;
      }
    };

    this.utterance.onend = () => {
      this.clearHighlight();
      this.pushEvent("read_aloud_stop", {});
    };

    this.utterance.onerror = () => {
      this.clearHighlight();
    };

    this.synth.speak(this.utterance);
  },

  pause() {
    if (this.synth && this.synth.speaking) {
      this.synth.pause();
    }
  },

  stop() {
    if (this.synth) {
      this.synth.cancel();
    }
    this.clearHighlight();
    this.text = "";
  },

  highlightWord(index, words) {
    this.clearHighlight();
    if (index >= words.length) return;
    const word = words[index];
    if (!word) return;

    const textLayer = this.el.querySelector(".textLayer");
    if (!textLayer) return;

    const regex = new RegExp(`(${word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")})`, "gi");
    const nodes = textLayer.querySelectorAll("span, div");
    for (const node of nodes) {
      if (regex.test(node.textContent)) {
        const match = node.textContent.match(regex);
        if (match) {
          node.innerHTML = node.textContent.replace(
            regex,
            '<mark class="read-aloud-highlight">$1</mark>'
          );
          const mark = node.querySelector("mark");
          if (mark) mark.scrollIntoView({ block: "center", behavior: "smooth" });
          return;
        }
      }
    }
  },

  clearHighlight() {
    this.el.querySelectorAll(".read-aloud-highlight").forEach((el) => {
      const parent = el.parentNode;
      parent.replaceChild(document.createTextNode(el.textContent), el);
      parent.normalize();
    });
  },

  destroyed() {
    this.stop();
  },
};

export default ReadAloudHook;
