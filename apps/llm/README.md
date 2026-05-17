# Llm

`apps/llm` is the local LLM boundary for `editor_umbrella`.

It owns three jobs:

1. starting and checking the local `llama-server` runtime,
2. building grounded editor context from the current workspace,
3. sending editor questions to the local model or the OpenCode ACP agent path.

The app is intentionally local-first. It is designed for code review, explanation, implementation guidance, and small refactor suggestions inside the browser editor without depending on a hosted API.

## Main Modules

| Module | Role |
| --- | --- |
| `Llm` | Public API for chat, agent chat, context building, status checks, and session reset. |
| `Llm.LlamaServer` | Starts and monitors a local `llama-server` process on `127.0.0.1:8000`. |
| `Llm.Client` | Sends OpenAI-compatible chat requests to `llama-server`. |
| `Llm.OpenCodeACP` | Owns a long-lived `opencode acp` subprocess and tracks ACP sessions per workspace. |
| `Llm.Rag` | Editor-aware retrieval boundary. Builds project memory and returns a prompt-ready context pack. |
| `Llm.ProjectMemory` | In-memory project snapshot made of file summaries, file chunks, pinned refs, and recent refs. |
| `Llm.ContextPack` | Compact bundle of messages, refs, summaries, metadata, and token estimates for a single request. |
| `Llm.ContextPack.Builder` | Main prompt assembly path for grounded editor requests. |
| `Llm.Prompts` | Shared prompt helpers, message constructors, truncation, prompt stats, and legacy direct prompt builders. |
| `Llm.Conversation` | Stores recent turns and summaries for editor conversation continuity. |
| `Llm.Codex` | Placeholder GenServer boundary for future Codex-oriented workflows. |

## Editor Request Flow

The browser editor path currently runs through `EditorWeb.EditorLlm`:

```text
EditorWeb.EditorLlm.agent_chat/2
  -> Llm.build_context/4
  -> Llm.Rag.build_context/4
  -> Llm.ProjectMemory.Builder.build/2
  -> Llm.ContextPack.Builder.build/2
  -> Llm.agent_chat/2
  -> Llm.OpenCodeACP.prompt/2
```

The request context includes:

- the selected file, when one is open,
- related files selected by the editor,
- open editor buffers from `Editor.OpenFileCache`,
- recent conversation turns,
- a conversation summary,
- token-budget metadata for the UI.

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

## Current Agent Path Caveat

The editor UI currently calls `Llm.agent_chat/2`, which wraps the built context into a final-answer prompt for `opencode acp`.

That final wrapper is built in `Llm.build_agent_prompt/4`. It forwards selected context snippets, file metadata, open-buffer context, and final-answer rules. It does not replay every system contract from `Llm.ContextPack.Builder` verbatim.

Practical rule:

- For direct llama-server chat behavior, inspect `Llm.ContextPack.Builder` and `Llm.Prompts`.
- For the editor modal / OpenCode ACP behavior, inspect `Llm.build_agent_prompt/4` and `final_answer_instructions/1` in `Llm` first.

If the editor assistant ignores a context-pack contract, the fix probably belongs in `Llm.build_agent_prompt/4` or `final_answer_instructions/1`, not only in `Llm.ContextPack.Builder`.

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

The main config lives in the umbrella `config/config.exs`:

```elixir
config :llm,
  enabled: true,
  model: "~/models/Qwen2.5-Coder-7B-Instruct-Q5_K_M.gguf",
  llama_dir: "~/llama.cpp",
  llama_server_path: "build/bin/llama-server",
  host: "127.0.0.1",
  port: 8000,
  flash_attention: "on",
  gpu_layers: "auto",
  parallel_slots: 1,
  context_size: 32_768,
  max_tokens: 8_192,
  batch_size: 2_048,
  micro_batch_size: 512,
  startup_wait_ms: 30_000,
  poll_interval_ms: 500,
  tcp_connect_timeout_ms: 1_000,
  client_receive_timeout: :infinity,
  client_connect_timeout_ms: 5_000,
  opencode_acp_enabled: true,
  opencode_cmd: "opencode",
  opencode_args: ["acp"],
  opencode_cwd: File.cwd!()
```

`Llm.LlamaServer` reads its llama.cpp path, bind address, tuning flags, and startup timing from `config :llm`. Paths that can contain `~` are expanded before use.

The configured `llama-server` defaults are tuned for local coding work:

```text
host: 127.0.0.1
port: 8000
context: 32768
max output tokens: 8192
parallel slots: 1
batch: 2048
micro-batch: 512
flash attention: on
gpu layers: auto
```

The default config assumes a local `llama.cpp` checkout at:

```text
~/llama.cpp
```

and a server executable at:

```text
~/llama.cpp/build/bin/llama-server
```

## OpenCode ACP Configuration

`Llm.OpenCodeACP` defaults to:

```text
opencode acp
```

Its startup behavior is configured in the same `config :llm` block:

```elixir
config :llm,
  opencode_acp_enabled: true,
  opencode_cmd: "opencode",
  opencode_args: ["acp"],
  opencode_cwd: File.cwd!()
```

Sessions are tracked per workspace `cwd`, so separate project roots should not trample each other.

Useful runtime checks:

```elixir
Llm.opencode_acp_running?()
Llm.opencode_acp_state()
Llm.reset_agent_session(File.cwd!())
```

## Prompt Debugging

Useful inspection points from IEx:

```elixir
Llm.status()
Llm.ready?()
Llm.LlamaServer.model_path()
Llm.opencode_acp_state()
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
- `Llm.build_agent_prompt/4` for the editor modal / OpenCode ACP prompt wrapper.
- `Llm.Prompts` for shared helpers, message constructors, truncation, and legacy direct prompt builders.
- `EditorWeb.EditorLlm` for what editor state is passed into the LLM request.

Avoid adding new prompt rules to only one path unless that path is intentionally the only caller.
