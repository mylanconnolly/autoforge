import { Terminal } from "../../vendor/xterm";
import { FitAddon } from "../../vendor/xterm-addon-fit";
import { WebLinksAddon } from "../../vendor/xterm-addon-web-links";
import { Socket } from "phoenix";

const terminalTheme = {
  background: "#1c1917",
  foreground: "#e7e5e4",
  cursor: "#e7e5e4",
  cursorAccent: "#1c1917",
  selectionBackground: "#44403c",
  selectionForeground: "#e7e5e4",
  black: "#1c1917",
  red: "#f87171",
  green: "#4ade80",
  yellow: "#facc15",
  blue: "#60a5fa",
  magenta: "#c084fc",
  cyan: "#22d3ee",
  white: "#e7e5e4",
  brightBlack: "#a8a29e",
  brightRed: "#fca5a5",
  brightGreen: "#86efac",
  brightYellow: "#fde68a",
  brightBlue: "#93c5fd",
  brightMagenta: "#d8b4fe",
  brightCyan: "#67e8f9",
  brightWhite: "#fafaf9",
};

const TerminalHook = {
  mounted() {
    const projectId = this.el.dataset.projectId;
    const userToken = this.el.dataset.userToken;

    this.term = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: "'IBM Plex Mono', monospace",
      theme: terminalTheme,
    });

    this.fitAddon = new FitAddon();
    this.term.loadAddon(this.fitAddon);
    this.term.loadAddon(new WebLinksAddon());

    this.term.open(this.el);
    this.fitAddon.fit();

    // Connect to terminal channel
    this.socket = new Socket("/socket", { params: { token: userToken } });
    this.socket.connect();

    this.channel = this.socket.channel(`terminal:${projectId}`, {});

    this.channel
      .join()
      .receive("ok", () => {
        this.term.writeln("\x1b[32mConnected to sandbox terminal.\x1b[0m\r\n");
      })
      .receive("error", (resp) => {
        this.term.writeln(
          `\x1b[31mFailed to connect: ${JSON.stringify(resp)}\x1b[0m\r\n`,
        );
      });

    // Terminal input → channel
    this.term.onData((data) => {
      this.channel.push("input", { data: data });
    });

    // Channel output → terminal
    this.channel.on("output", (payload) => {
      this.term.write(payload.data);
    });

    // Resize handling
    this.resizeObserver = new ResizeObserver(() => {
      if (this.el.clientWidth === 0 || this.el.clientHeight === 0) return;
      this.fitAddon.fit();
      const dims = this.fitAddon.proposeDimensions();
      if (dims && this.channel) {
        this.channel.push("resize", { cols: dims.cols, rows: dims.rows });
      }
    });
    this.resizeObserver.observe(this.el);

    // Re-fit when parent panel becomes visible (tab switch)
    const panel = this.el.parentElement;
    if (panel) {
      this.mutationObserver = new MutationObserver(() => {
        if (!panel.classList.contains("invisible")) {
          this.fitAddon.fit();
          this.term.focus();
        }
      });
      this.mutationObserver.observe(panel, {
        attributes: true,
        attributeFilter: ["class"],
      });
    }
  },

  destroyed() {
    if (this.channel) {
      this.channel.leave();
    }
    if (this.socket) {
      this.socket.disconnect();
    }
    if (this.term) {
      this.term.dispose();
    }
    if (this.resizeObserver) {
      this.resizeObserver.disconnect();
    }
    if (this.mutationObserver) {
      this.mutationObserver.disconnect();
    }
  },
};

const ProvisionLogHook = {
  mounted() {
    this.term = new Terminal({
      cursorBlink: false,
      disableStdin: true,
      fontSize: 14,
      fontFamily: "'IBM Plex Mono', monospace",
      scrollback: 10000,
      theme: { ...terminalTheme, cursor: "#1c1917" },
    });

    this.fitAddon = new FitAddon();
    this.term.loadAddon(this.fitAddon);
    this.term.loadAddon(new WebLinksAddon());

    this.term.open(this.el);
    this.fitAddon.fit();

    this.resizeObserver = new ResizeObserver(() => {
      this.fitAddon.fit();
    });
    this.resizeObserver.observe(this.el);

    this.handleEvent("provision_log", ({ type, data }) => {
      if (type === "step") {
        this.term.writeln(`\x1b[33m${data}\x1b[0m`);
      } else {
        this.term.write(data);
      }
    });
  },

  destroyed() {
    if (this.term) this.term.dispose();
    if (this.resizeObserver) this.resizeObserver.disconnect();
  },
};

export default TerminalHook;
export { ProvisionLogHook };
