import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/editor_web"
import topbar from "../vendor/topbar"
import {EditorState} from "@codemirror/state"
import {EditorView, keymap, lineNumbers, highlightActiveLineGutter} from "@codemirror/view"
import {defaultKeymap, history, historyKeymap, indentWithTab} from "@codemirror/commands"
import {syntaxHighlighting, defaultHighlightStyle, bracketMatching} from "@codemirror/language"
import {javascript} from "@codemirror/lang-javascript"
import {html} from "@codemirror/lang-html"
import {elixir} from "codemirror-lang-elixir"
import {markdown} from "@codemirror/lang-markdown"

const FOLDER_STORAGE_KEY = "editor:last_folder_path"
const FILE_STORAGE_KEY = "editor:last_file_path"
const LLM_MODAL_OPEN_KEY = "editor:llm_modal_open"
const LLM_RESPONSE_KEY = "editor:llm_response"
const LLM_CONTEXT_KEY = "editor:llm_context"

function languageExtension(path) {
  if (!path) return []

  if (path.endsWith(".ex") || path.endsWith(".exs")) {
    return [elixir()]
  }

  if (path.endsWith(".heex") || path.endsWith(".html")) {
    return [html()]
  }

  if (path.endsWith(".js") || path.endsWith(".mjs") || path.endsWith(".cjs")) {
    return [javascript()]
  }

  if (path.endsWith(".md") || path.endsWith(".markdown")) {
    return [markdown()]
  }

  return []
}

function buildEditorExtensions(hook, path) {
  return [
    lineNumbers(),
    highlightActiveLineGutter(),
    history(),
    bracketMatching(),
    syntaxHighlighting(defaultHighlightStyle),
    keymap.of([indentWithTab, ...defaultKeymap, ...historyKeymap]),
    ...languageExtension(path),
    EditorView.lineWrapping,
    EditorView.updateListener.of((update) => {
      if (!update.docChanged) return

      const value = update.state.doc.toString()
      hook.lastValue = value
      hook.pushEvent("edit_file", {editor: {content: value}})
    }),
    EditorView.theme({
      "&": {
        height: "100%",
        fontSize: "14px"
      },
      ".cm-scroller": {
        overflow: "auto",
        fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace"
      },
      ".cm-content": {
        minHeight: "100%",
        padding: "16px"
      },
      ".cm-gutters": {
        borderRight: "1px solid var(--color-base-300)",
        backgroundColor: "var(--color-base-200)"
      }
    })
  ]
}

const Hooks = {
  FolderPathStorage: {
    mounted() {
      this.storageKey = this.el.dataset.storageKey
      this.input = this.el.querySelector("#folder-path")

      if (!this.input || !this.storageKey) return

      const savedPath = window.localStorage.getItem(this.storageKey)

      if (savedPath && savedPath !== this.input.value) {
        this.input.value = savedPath
        this.pushEvent("restore_path", {folder_path: savedPath})
      }

      this.onSubmit = () => {
        window.localStorage.setItem(this.storageKey, this.input.value)
        window.localStorage.removeItem(FILE_STORAGE_KEY)
      }

      this.el.addEventListener("submit", this.onSubmit)
    },

    destroyed() {
      if (this.onSubmit) {
        this.el.removeEventListener("submit", this.onSubmit)
      }
    }
  },

  FileExplorerContextMenu: {
    mounted() {
      this.handleContextMenu = (event) => {
        const fileTarget = event.target.closest("[data-context-file-path]")
        const folderTarget = event.target.closest("[data-context-folder-path]")

        if (fileTarget && this.el.contains(fileTarget)) {
          event.preventDefault()

          this.pushEvent("show_file_context_menu", {
            path: fileTarget.dataset.contextFilePath,
            x: event.clientX,
            y: event.clientY
          })

          return
        }

        if (!folderTarget || !this.el.contains(folderTarget)) return

        event.preventDefault()

        this.pushEvent("show_folder_context_menu", {
          path: folderTarget.dataset.contextFolderPath,
          x: event.clientX,
          y: event.clientY
        })
      }

      this.handleDocumentClick = (event) => {
        const menu =
          document.getElementById("folder-context-menu") ||
          document.getElementById("file-context-menu")

        if (menu && menu.contains(event.target)) return

        this.pushEvent("hide_context_menus", {})
      }

      this.handleKeydown = (event) => {
        if (event.key === "Escape") {
          this.pushEvent("hide_context_menus", {})
        }
      }

      this.handleCopy = (event) => {
        const button = event.target.closest("[data-clipboard-text]")

        if (!button) return

        const text = button.dataset.clipboardText || ""

        navigator.clipboard.writeText(text).then(() => {
          this.pushEvent("hide_context_menus", {})
        })
      }

      this.el.addEventListener("contextmenu", this.handleContextMenu)
      document.addEventListener("click", this.handleCopy)
      document.addEventListener("click", this.handleDocumentClick)
      document.addEventListener("keydown", this.handleKeydown)
    },

    destroyed() {
      this.el.removeEventListener("contextmenu", this.handleContextMenu)
      document.removeEventListener("click", this.handleCopy)
      document.removeEventListener("click", this.handleDocumentClick)
      document.removeEventListener("keydown", this.handleKeydown)
    }
  },

  EditorShell: {
    mounted() {
      this.persist()
    },

    updated() {
      this.persist()
    },

    persist() {
      const selectedFilePath = this.el.dataset.selectedFilePath || ""
      const llmModalOpen = this.el.dataset.llmModalOpen || "false"

      if (selectedFilePath === "") {
        window.localStorage.removeItem(FILE_STORAGE_KEY)
      } else {
        window.localStorage.setItem(FILE_STORAGE_KEY, selectedFilePath)
      }

      window.localStorage.setItem(LLM_MODAL_OPEN_KEY, llmModalOpen)

      // Clear legacy LLM payloads so LiveView connect params stay small.
      window.localStorage.removeItem(LLM_RESPONSE_KEY)
      window.localStorage.removeItem(LLM_CONTEXT_KEY)
      window.localStorage.removeItem("editor:llm_question")
    }
  },

  CopyCodeBlock: {
    mounted() {
      this.handleCopy = () => {
        const code = this.el.dataset.code || this.el.textContent || ""
        navigator.clipboard.writeText(code)
      }

      this.el.addEventListener("editor:copy", this.handleCopy)
    },

    destroyed() {
      if (this.handleCopy) {
        this.el.removeEventListener("editor:copy", this.handleCopy)
      }
    }
  },

  CodeEditor: {
    mounted() {
      this.lastValue = this.el.dataset.content || ""
      this.lastPath = this.el.dataset.path || ""

      this.view = new EditorView({
        state: EditorState.create({
          doc: this.lastValue,
          extensions: buildEditorExtensions(this, this.lastPath)
        }),
        parent: this.el
      })
    },

    updated() {
      if (!this.view) return

      const nextValue = this.el.dataset.content || ""
      const nextPath = this.el.dataset.path || ""

      if (nextPath !== this.lastPath) {
        this.lastPath = nextPath
        this.lastValue = nextValue

        this.view.setState(
          EditorState.create({
            doc: nextValue,
            extensions: buildEditorExtensions(this, nextPath)
          })
        )

        return
      }

      if (nextValue !== this.lastValue) {
        this.lastValue = nextValue

        this.view.dispatch({
          changes: {
            from: 0,
            to: this.view.state.doc.length,
            insert: nextValue
          }
        })
      }
    },

    destroyed() {
      if (this.view) {
        this.view.destroy()
      }
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => ({
    _csrf_token: csrfToken,
    stored_folder_path: window.localStorage.getItem(FOLDER_STORAGE_KEY),
    stored_file_path: window.localStorage.getItem(FILE_STORAGE_KEY),
    stored_llm_modal_open: window.localStorage.getItem(LLM_MODAL_OPEN_KEY)
  }),
  hooks: {...colocatedHooks, ...Hooks},
})

topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()

    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", () => keyDown = null)
    window.addEventListener("click", e => {
      if (keyDown === "c") {
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if (keyDown === "d") {
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
