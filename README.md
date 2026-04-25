# Editor.Umbrella

`editor_umbrella` is a Phoenix umbrella project for a browser-based text editor with a local LLM assistant.

The goal of the project is to combine a lightweight file editor, persistent workspace state, and an on-device code assistant into one development environment.

## What This Project Does

The app currently centers around a LiveView-powered editor interface that can:

- browse folders and drill into files
- open and edit files in the browser
- save files back to disk
- remember the last open folder and file across reloads
- ask a locally running LLM questions about the file you currently have open
- render LLM responses inside the editor UI
- preserve LLM modal state in local storage
- support richer editor behavior through JavaScript hooks

The LLM integration is designed to work with a local `llama-server` process, so questions about the current file can be answered without depending on a hosted API.

## Umbrella Apps

This umbrella currently includes:

- `apps/editor`
  Core application code and shared editor domain logic.

- `apps/editor_web`
  Phoenix web interface, LiveView UI, assets, hooks, and browser-side editor behavior.

- `apps/llm`
  Local LLM integration, prompt construction, client requests, and `llama-server` lifecycle management.

## Architecture

At a high level:

- `EditorWeb.EditorLive` drives the file browser and editing workflow.
- The editor UI keeps track of the current file, current content, dirty state, and save lifecycle.
- LLM prompt construction lives in `Llm.Prompts`.
- LLM requests go through `Llm` and `Llm.Client`.
- `Llm.LlamaServer` is responsible for starting and monitoring the local model server.
- JavaScript hooks in `apps/editor_web/assets/js/app.js` handle client-side state persistence and enhanced editor behavior.

## Local LLM Workflow

The project is set up to use a local model server instead of a hosted provider.

Current direction:

- start `llama-server` from the `llm` app when needed
- send the current in-memory file contents to the model
- ask questions about the active file directly from the editor UI
- keep prompts centralized so editor behaviors stay predictable

This makes the editor useful for:

- reviewing a file
- explaining code
- answering questions about unsaved changes
- experimenting with refactors before applying them manually

## Development

From the umbrella root:

```bash
mix setup
```

Start the Phoenix app:

```bash
mix phx.server
```

If you are working on frontend assets, build them with:

```bash
mix assets.build
```

Run the project checks:

```bash
mix precommit
```

## Direction

This project is not just a text area with chat attached to it.

The intended direction is a practical editor experience where LLM features are tied to concrete editing workflows, such as:

- ask about the current file
- explain a selected region
- review a file
- propose a refactor
- generate code or tests in context

The emphasis is on keeping the model useful, local, and grounded in the file being edited.