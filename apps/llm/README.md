# Llm

`apps/llm` is the local LLM boundary for `editor_umbrella`.

It owns three jobs:

1. starting and checking the local `llama-server` runtime,
2. building grounded editor context from the current workspace,
3. running editor questions through a native tool-calling loop against the local model.

The app is intentionally local-first. It is designed for code review, explanation, implementation guidance, and small refactor suggestions inside the browser editor without depending on a hosted API.

## Main Modules

| Module | Role |
| --- | --- |
| `Llm` | Public API for chat, tool chat, context building, and status checks. |
| `Llm.LlamaServer` | Starts and monitors a local `llama-server` process on `127.0.0.1:8000`. |
| `Llm.Client` | Sends OpenAI-compatible chat requests to `llama-server`. |
| `Llm.ToolLoop` | Bounded tool-call loop: send messages + tools, run requested tools, repeat until a final answer. |
| `Llm.ToolRouter` | Tool definitions and execution, clamped to the trusted workspace root. |
| `Llm.ModelOutput` | Strips leaked `<think>` blocks and parses tool calls the server left as text. |
| `Llm.Budget` | Prompt and tool-result size limits derived from the profile's context size. |
| `Llm.Sampling` | Default sampling settings from the profile `sampling:` list. |
| `Llm.Rag` | Editor-aware retrieval boundary. Builds project memory and returns a prompt-ready context pack. |
| `Llm.ProjectMemory` | In-memory project snapshot made of file summaries, file chunks, pinned refs, and recent refs. |
| `Llm.ContextPack` | Compact bundle of messages, refs, summaries, metadata, and token estimates for a single request. |
| `Llm.ContextPack.Builder` | Main prompt assembly path for grounded editor requests. |
| `Llm.Prompts` | Shared prompt helpers, message constructors, truncation, prompt stats, and legacy direct prompt builders. |
| `Llm.Conversation` | Stores recent turns and summaries for editor conversation continuity. |

## Editor Request Flow

The browser editor path currently runs through `EditorWeb.EditorLlm`:

```text
EditorWeb.EditorLlm.tool_agent_chat/2
  -> Llm.tool_chat/2
  -> Llm.ToolLoop.run/2
       -> Llm.Client.chat_completion/2   (llama-server /v1/chat/completions)
       -> Llm.ToolRouter.call/2          (when the model requests a tool)
```

The request includes:

- a stable system message (architectural lens, code rules, workspace root, tool rules),
- the selected file path, git status and related-file relationships,
- open editor buffers from `Editor.OpenFileCache`, capped by `Llm.Budget`,
- an intent contract for review/refactor/implementation questions,
- the editor tool schemas from `Llm.ToolRouter.tools/0`.

Everything that changes between requests goes in the user message so the system
message and tool schemas stay identical and llama-server can reuse its prompt cache.
Tool calls are scoped to the editor's open workspace (`workspace_root:`).

Open editor buffers are important because they may include unsaved edits. When buffer content overlaps with on-disk project-memory snippets, the assistant should prefer the buffer content.

## Prompting Layers

Prompting is split into several layers.

### 1. Project memory

`Llm.ProjectMemory.Builder` scans supported source files under the workspace root and builds:

- file summaries,
- module names,
- public symbols,
- file chunks,
- SHA hashes,
- basic metadata such as byte size and line count.

Elixir files are chunked by function when possible. Other files fall back to line-based chunks.

Supported extensions currently come from `Llm.Prompts.wanted_file?/1`:

```text
.ex .exs .heex .js .ts .tsx .json .md
```

Skipped paths include `_build`, `deps`, `node_modules`, `.git`, `.elixir_ls`, and generated static asset paths.

### 2. Context pack

`Llm.ContextPack.Builder` chooses the small set of refs and snippets that should be sent for one request.

The context pack includes:

- current file refs,
- retrieved project-context refs,
- open-file refs,
- related-file metadata,
- conversation summary,
- recent messages,
- final system/user messages,
- estimated token count.

The default prompt budget is `16_384` estimated tokens unless the caller passes another `:token_budget`.

### 3. Grounding contract

The main context-pack prompt tells the model to answer from visible snippets and relevant-file summaries. It also tells the model to name the exact file paths, modules, functions, assigns, plugs, callbacks, or events it used.

The grounding rules are meant to prevent common local-agent failures:

- inventing modules or application names,
- treating prior assistant messages as source-code evidence,
- assuming Phoenix Presence metadata is the authenticated user,
- claiming a function exists without seeing it in the snippets,
- proposing patches at the wrong event boundary.

### 4. Intent-specific contracts

`Llm.ContextPack.Builder` adds extra contracts for certain request types.

Refactor requests are detected with terms such as:

```text
refactor, rewrite, clean up, improve, restructure
```

Refactor responses should avoid whole-module dumps. They should return only changed functions/docs or a focused unified diff.

Review requests are detected with terms such as:

```text
review, check, audit, look over
```

Review responses should inspect the selected current file first and should not ask which file to review.

Implementation requests are detected with terms such as:

```text
how can, how do, implement, add, include, wire, connect, notify, broadcast, when, on join
```

Implementation responses should distinguish existing code from proposed code, avoid invented APIs, avoid unreachable callback changes, and name the visible producer/consumer boundary when event wiring is involved.

## Direct Chat Path

The lower-level direct chat path is still available:

```elixir
Llm.chat("Explain this module")
```

or:

```elixir
messages = [
  Llm.Prompts.system_message("You are a coding assistant."),
  Llm.Prompts.user_message("Explain this module.")
]

Llm.chat(messages)
```

Direct chat uses `Llm.Client`, which posts to:

```text
http://127.0.0.1:8000/v1/chat/completions
```

## Runtime Configuration

The local model config lives in the umbrella `config/llama.exs`, imported by
`config/config.exs`. It defines model profiles and picks one with `LLM_PROFILE`:

```bash
LLM_PROFILE=qwen3.6-35b mix phx.server   # default profile: qwen3-4b
```

Each profile sets the GGUF path, `context_size`, `max_tokens`, `micro_batch_size`,
a `sampling:` list, and `extra_args` appended verbatim to the `llama-server` command.

`Llm.LlamaServer` reads its llama.cpp path, bind address, Qwen3 chat-template flags,
sampling defaults, and startup timing from `config :llm`. Paths that can contain
`~` are expanded before use.

The default config assumes a local `llama.cpp` checkout at `~/llama.cpp` with the
server executable at `~/llama.cpp/build/bin/llama-server`.

## Prompt Debugging

Useful inspection points from IEx:

```elixir
Llm.status()
Llm.ready?()
Llm.LlamaServer.model_path()
Llm.LlamaServer.server_args()
```

Build a context pack manually:

```elixir
{:ok, context} =
  Llm.build_context(
    File.cwd!(),
    "apps/editor_web/lib/editor_web/live/editor_live.ex",
    "Review this file",
    token_budget: 16_384
  )

context.pack.estimated_tokens
Llm.ContextPack.referenced_paths(context.pack)
Enum.map(context.messages, &{&1.role, String.slice(&1.content, 0, 120)})
```

See prompt statistics:

```elixir
Llm.Prompts.stats(context.messages)
```

## Testing

Run the LLM app tests from the umbrella root:

```bash
mix test apps/llm/test
```

Useful focused tests are in:

```text
apps/llm/test/llm_test.exs
```

The current tests cover:

- disabled LLM behavior,
- model path config,
- folder/file prompt construction,
- truncation behavior,
- related-file specs,
- open-file context,
- RAG context construction,
- conversation memory,
- token-budget trimming,
- function-based Elixir chunking,
- grounding instructions,
- review/refactor/implementation contracts.

## Development Notes

When changing prompting behavior, update the tests with the prompt contract you expect.

Good places to change behavior:

- `Llm.ContextPack.Builder` for RAG context selection and direct context-pack messages.
- `EditorWeb.EditorLlm.tool_agent_chat/2` for the editor modal's system/user messages.
- `Llm.ToolLoop` and `Llm.ModelOutput` for how model replies and tool calls are handled.
- `Llm.Prompts` for shared helpers, message constructors, truncation, and legacy direct prompt builders.
- `EditorWeb.EditorLlm` for what editor state is passed into the LLM request.

Avoid adding new prompt rules to only one path unless that path is intentionally the only caller.
