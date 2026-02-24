import { Terminal } from "../../vendor/xterm";
import { FitAddon } from "../../vendor/xterm-addon-fit";
import { WebLinksAddon } from "../../vendor/xterm-addon-web-links";
import { Socket } from "phoenix";

const TerminalHook = {
  mounted() {
    const projectId = this.el.dataset.projectId;
    const userToken = this.el.dataset.userToken;

    this.term = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: "'IBM Plex Mono', monospace",
      theme: {
        background: "#1c1917",
        foreground: "#e7e5e4",
        cursor: "#e7e5e4",
        selectionBackground: "#44403c",
      },
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
      this.fitAddon.fit();
      const dims = this.fitAddon.proposeDimensions();
      if (dims) {
        this.channel.push("resize", { cols: dims.cols, rows: dims.rows });
      }
    });
    this.resizeObserver.observe(this.el);
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
      theme: {
        background: "#1c1917",
        foreground: "#e7e5e4",
        cursor: "#1c1917",
        selectionBackground: "#44403c",
      },
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
