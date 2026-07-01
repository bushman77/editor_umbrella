import Config

# -----------------------------------------------------------------------------
# Local llama.cpp / Qwen configuration
# -----------------------------------------------------------------------------
#
# This file owns all local LLM runtime configuration for editor_umbrella.
#
# The bash launcher we tested is only a reference now. In normal app usage,
# llama-server should be started and monitored by Llm.Application ->
# Llm.LlamaServer.
# -----------------------------------------------------------------------------

config :llm,
  enabled: true,

  # OpenAI-compatible model name sent in /v1/chat/completions payloads.
  # Keep this aligned with the llama-server --alias value.
  model_name: "local-model",
  # GGUF model used by this project.
  model: "~/models/qwen2.5-7b-instruct-gguf/Qwen2.5-7B-Instruct-Q4_K_M.gguf",

  # llama.cpp runtime.
  llama_dir: "~/llama.cpp",
  llama_server_path: "build/bin/llama-server",

  # Local-only app-owned server.
  host: "127.0.0.1",
  port: 8000,

  # llama-server model/runtime flags.
  alias: "local-model",
  jinja: true,
  flash_attention: "on",
  gpu_layers: "auto",
  parallel_slots: 1,
  context_size: 32_768,
  max_tokens: 8_192,
  batch_size: 2_048,
  micro_batch_size: 512,

  # Startup/readiness behavior.
  startup_wait_ms: 30_000,
  poll_interval_ms: 500,
  tcp_connect_timeout_ms: 1_000,

  # Req client behavior.
  client_receive_timeout: :infinity,
  client_connect_timeout_ms: 5_000,

  # Native Qwen tool-calling path is the direction now.
  # Keep OpenCode ACP out of the default path.
  opencode_acp_enabled: false,
  opencode_cmd: "opencode",
  opencode_args: ["acp"],
  opencode_cwd: File.cwd!()
