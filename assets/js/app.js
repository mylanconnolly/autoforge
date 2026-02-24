// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/autoforge";
import topbar from "../vendor/topbar";
import { Hooks as FluxonHooks, DOM as FluxonDOM } from "fluxon";

const ChatScroll = {
  mounted() {
    this.el.scrollTop = this.el.scrollHeight;
    this.observer = new MutationObserver(() => {
      this.el.scrollTop = this.el.scrollHeight;
    });
    this.observer.observe(this.el, { childList: true, subtree: true });
  },
  updated() {
    this.el.scrollTop = this.el.scrollHeight;
  },
  destroyed() {
    if (this.observer) this.observer.disconnect();
  },
};

const ChatInput = {
  mounted() {
    this.el.focus();
    this.bots = JSON.parse(this.el.dataset.bots || "[]");
    this.mentionActive = false;
    this.mentionStart = -1;
    this.mentionQuery = "";
    this.filteredBots = [];
    this.selectedIndex = 0;
    this.dropdown = null;

    this.resize = () => {
      this.el.style.height = "auto";
      this.el.style.height = this.el.scrollHeight + "px";
    };

    this.createDropdown();

    this.el.addEventListener("input", (e) => {
      this.resize();
      this.handleMentionInput();
    });

    this.el.addEventListener("keydown", (e) => {
      if (this.mentionActive && this.filteredBots.length > 0) {
        if (e.key === "ArrowDown") {
          e.preventDefault();
          this.selectedIndex = (this.selectedIndex + 1) % this.filteredBots.length;
          this.renderDropdown();
          return;
        }
        if (e.key === "ArrowUp") {
          e.preventDefault();
          this.selectedIndex = (this.selectedIndex - 1 + this.filteredBots.length) % this.filteredBots.length;
          this.renderDropdown();
          return;
        }
        if (e.key === "Enter" || e.key === "Tab") {
          e.preventDefault();
          this.selectBot(this.filteredBots[this.selectedIndex]);
          return;
        }
        if (e.key === "Escape") {
          e.preventDefault();
          this.hideMentionDropdown();
          return;
        }
      }

      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        if (this.el.value.trim() !== "") {
          this.el.closest("form").dispatchEvent(
            new Event("submit", { bubbles: true, cancelable: true })
          );
          this.el.value = "";
          this.resize();
        }
      }
    });

    this.outsideClickHandler = (e) => {
      if (this.dropdown && !this.dropdown.contains(e.target) && e.target !== this.el) {
        this.hideMentionDropdown();
      }
    };
    document.addEventListener("mousedown", this.outsideClickHandler);

    this.handleEvent("clear_input", () => {
      this.el.value = "";
      this.resize();
      this.el.focus();
      this.hideMentionDropdown();
    });
  },

  updated() {
    this.bots = JSON.parse(this.el.dataset.bots || "[]");
  },

  destroyed() {
    document.removeEventListener("mousedown", this.outsideClickHandler);
    if (this.dropdown && this.dropdown.parentNode) {
      this.dropdown.parentNode.removeChild(this.dropdown);
    }
  },

  createDropdown() {
    this.dropdown = document.createElement("div");
    this.dropdown.className =
      "absolute bottom-full left-0 mb-1 w-64 bg-base-200 border border-base-300 rounded-lg shadow-lg overflow-hidden z-50 hidden";
    document.getElementById("mention-dropdown-container").appendChild(this.dropdown);
  },

  handleMentionInput() {
    const value = this.el.value;
    const cursor = this.el.selectionStart;
    const textBeforeCursor = value.substring(0, cursor);
    const match = textBeforeCursor.match(/(^|[\s])@(\w*)$/);

    if (match && this.bots.length > 0) {
      this.mentionActive = true;
      this.mentionStart = cursor - match[2].length - 1;
      this.mentionQuery = match[2].toLowerCase();
      this.filterAndShowBots();
    } else {
      this.hideMentionDropdown();
    }
  },

  filterAndShowBots() {
    this.filteredBots = this.bots.filter((bot) =>
      bot.name.toLowerCase().includes(this.mentionQuery)
    );

    if (this.filteredBots.length === 0) {
      this.hideMentionDropdown();
      return;
    }

    this.selectedIndex = Math.min(this.selectedIndex, this.filteredBots.length - 1);
    this.renderDropdown();
    this.dropdown.classList.remove("hidden");
  },

  renderDropdown() {
    this.dropdown.innerHTML = "";
    this.filteredBots.forEach((bot, index) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = this.itemClass(index === this.selectedIndex);
      btn.textContent = "@" + bot.name;
      btn.addEventListener("mousedown", (e) => {
        e.preventDefault();
        this.selectBot(bot);
      });
      btn.addEventListener("mouseenter", () => {
        this.selectedIndex = index;
        this.updateSelection();
      });
      this.dropdown.appendChild(btn);
    });
  },

  updateSelection() {
    const items = this.dropdown.children;
    for (let i = 0; i < items.length; i++) {
      items[i].className = this.itemClass(i === this.selectedIndex);
    }
  },

  itemClass(selected) {
    return (
      "w-full text-left px-3 py-2 text-sm transition-colors " +
      (selected
        ? "bg-primary/15 text-base-content"
        : "text-base-content/80 hover:bg-base-300")
    );
  },

  selectBot(bot) {
    const before = this.el.value.substring(0, this.mentionStart);
    const after = this.el.value.substring(this.el.selectionStart);
    const insertion = "@" + bot.name + " ";
    this.el.value = before + insertion + after;
    const newCursor = before.length + insertion.length;
    this.el.setSelectionRange(newCursor, newCursor);
    this.hideMentionDropdown();
    this.el.focus();
  },

  hideMentionDropdown() {
    this.mentionActive = false;
    this.mentionQuery = "";
    this.filteredBots = [];
    this.selectedIndex = 0;
    if (this.dropdown) {
      this.dropdown.classList.add("hidden");
    }
  },
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: { ...colocatedHooks, ...FluxonHooks, ChatScroll, ChatInput },
  dom: {
    onBeforeElUpdated(from, to) {
      FluxonDOM.onBeforeElUpdated(from, to);
    },
  },
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#f59e0b" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();

      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (_e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );

      window.liveReloader = reloader;
    },
  );
}
