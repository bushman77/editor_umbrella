import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/editor_web"
import topbar from "../vendor/topbar"

const FILE_STORAGE_KEY = "editor:last_file_path"

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

  SelectedFileStorage: {
    mounted() {
      this.lastPath = null
      this.persistSelectedFile()
      this.handleUpdate = () => this.persistSelectedFile()
      this.handleEvent("file_opened", this.handleUpdate)
    },

    updated() {
      this.persistSelectedFile()
    },

    persistSelectedFile() {
      const path = this.el.dataset.selectedFilePath || ""

      if (path === this.lastPath) return

      this.lastPath = path

      if (path === "") {
        window.localStorage.removeItem(FILE_STORAGE_KEY)
      } else {
        window.localStorage.setItem(FILE_STORAGE_KEY, path)
      }
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
  LlmModalStorage: {
    mounted() {
      this.persist()
    },

    updated() {
      this.persist()
    },

    persist() {
      const isOpen = this.el.dataset.llmModalOpen === "true"
      const question = this.el.dataset.llmQuestion || ""
      const response = this.el.dataset.llmResponse || ""

      window.localStorage.setItem("editor:llm_modal_open", String(isOpen))
      window.localStorage.setItem("editor:llm_question", question)
      window.localStorage.setItem("editor:llm_response", response)
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: () => ({
    _csrf_token: csrfToken,
  stored_folder_path: window.localStorage.getItem("editor:last_folder_path"),
  stored_file_path: window.localStorage.getItem(FILE_STORAGE_KEY),
  stored_llm_modal_open: window.localStorage.getItem("editor:llm_modal_open"),
  stored_llm_question: window.localStorage.getItem("editor:llm_question"),
  stored_llm_response: window.localStorage.getItem("editor:llm_response")
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
