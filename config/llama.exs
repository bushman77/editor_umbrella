import Config

# -----------------------------------------------------------------------------
# Local llama.cpp / Qwen configuration
# -----------------------------------------------------------------------------
#
# This file owns all local LLM runtime configuration for editor_umbrella.
# llama-server is started and monitored by Llm.Application -> Llm.LlamaServer.
#
# Switch models without editing this file:
#
#     LLM_PROFILE=qwen3.6-35b mix phx.server
#
# Hardware target: RTX 3060 6 GB + 16 GB system RAM.
# -----------------------------------------------------------------------------

# presence_penalty: Qwen suggests 0-2 to stop endless repetition. Without it
# the 4B model can finish an answer and then loop on "Final Answer ✅ ✅ ✅"
# until max_tokens. Raise toward 1.5 if loops persist; too high can make it
# avoid repeating identifiers it legitimately needs.
profiles = %{
  # Small dense non-thinking model. Fits entirely in 6 GB VRAM.
  "qwen3-4b" => %{
    name: "Qwen/Qwen3-4B-Instruct-2507",
    path: "~/models/qwen3-4b-instruct-2507/Qwen_Qwen3-4B-Instruct-2507-Q5_K_M.gguf",
    context_size: 49_152,
    max_tokens: 16_384,
    micro_batch_size: 512,
    sampling: [temperature: 0.7, top_p: 0.8, top_k: 20, min_p: 0.0, presence_penalty: 1.0],
    extra_args: []
  },

  # 35B MoE (3B active). Experts spill to system RAM; thinking disabled so
  # reasoning tokens don't eat the ToolLoop's max_tokens budget.
  #
  # Only ~1 in 4 layers uses full attention, so the KV cache stays small and
  # 32k context is affordable. Prompt and tool-result budgets are derived
  # from context_size (see Llm.Budget). If llama-server fails to allocate,
  # drop to 24_576 before touching --n-cpu-moe.
  #
  # --n-cpu-moe N keeps the experts of the first N layers on the CPU. Lower it
  # until VRAM is nearly full (watch nvidia-smi) for more speed.
  "qwen3.6-35b" => %{
    name: "Qwen/Qwen3.6-35B-A3B",
    path: "~/models/Qwen3.6-35B-A3B-IQ3_S.gguf",
    context_size: 32_768,
    max_tokens: 4_096,
    micro_batch_size: 256,
    sampling: [temperature: 0.7, top_p: 0.8, top_k: 20, min_p: 0.0, presence_penalty: 1.0],
    extra_args: [
      "--n-cpu-moe",
      "30",
      "--cache-type-k",
      "q8_0",
      "--cache-type-v",
      "q8_0",
      "--chat-template-kwargs",
      ~s({"enable_thinking":false})
    ]
  }
}

profile_key = System.get_env("LLM_PROFILE", "qwen3-4b")

profile =
  Map.get(profiles, profile_key) ||
    raise "Unknown LLM_PROFILE #{inspect(profile_key)}. " <>
            "Available: #{profiles |> Map.keys() |> Enum.join(", ")}"

config :llm,
  enabled: true,
  profile: profile_key,

  # --- Model -----------------------------------------------------------------
  # model_name is sent in /v1/chat/completions payloads; alias is the
  # llama-server --alias. Both derive from the profile so they can't drift.
  model_name: profile.name,
  alias: profile.name,
  model: profile.path,

  # --- llama.cpp runtime -----------------------------------------------------
  llama_dir: "~/llama.cpp",
  llama_server_path: "build/bin/llama-server",
  host: "127.0.0.1",
  port: 8000,

  # --- llama-server flags ----------------------------------------------------
  flash_attention: "on",
  gpu_layers: "auto",
  parallel_slots: 1,
  context_size: profile.context_size,
  max_tokens: profile.max_tokens,
  batch_size: 2_048,
  micro_batch_size: profile.micro_batch_size,
  # Appended verbatim to the llama-server argv.
  extra_args: profile.extra_args,

  # --- Default request sampling ----------------------------------------------
  # Merged under per-call opts in Llm.Client (per-call opts win).
  sampling: profile.sampling,

  # --- Startup / readiness ---------------------------------------------------
  startup_wait_ms: 30_000,
  poll_interval_ms: 500,
  tcp_connect_timeout_ms: 1_000,

  # --- Req client ------------------------------------------------------------
  client_receive_timeout: :infinity,
  client_connect_timeout_ms: 5_000
