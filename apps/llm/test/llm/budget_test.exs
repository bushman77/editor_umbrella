defmodule Llm.BudgetTest do
  # Not async: some tests change :llm application env.
  use ExUnit.Case, async: false

  alias Llm.Budget

  setup do
    saved =
      Map.new(
        [:context_size, :max_tokens, :tool_result_max_chars],
        &{&1, Application.fetch_env(:llm, &1)}
      )

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:llm, key, value)
        {key, :error} -> Application.delete_env(:llm, key)
      end)
    end)

    Application.delete_env(:llm, :tool_result_max_chars)
    :ok
  end

  test "prompt budget leaves room for the answer and fixed overhead" do
    # 32_768 - 4_096 output - 3_000 overhead = 25_672 tokens * 3 chars
    assert Budget.prompt_char_budget(context_size: 32_768, max_tokens: 4_096) == 77_016
  end

  test "a 16k window gets a much smaller budget than a 49k one" do
    small = Budget.prompt_char_budget(context_size: 16_384, max_tokens: 4_096)
    large = Budget.prompt_char_budget(context_size: 49_152, max_tokens: 4_096)

    assert small == (16_384 - 4_096 - 3_000) * 3
    assert large > small * 3
  end

  test "a huge configured output size never reserves more than half the window" do
    assert Budget.prompt_char_budget(context_size: 49_152, max_tokens: 40_000) ==
             (49_152 - 24_576 - 3_000) * 3
  end

  test "falls back to :llm config and never drops below the floor" do
    Application.put_env(:llm, :context_size, 16_384)
    Application.put_env(:llm, :max_tokens, 4_096)
    assert Budget.prompt_char_budget() == (16_384 - 4_096 - 3_000) * 3

    assert Budget.prompt_char_budget(context_size: 4_096, max_tokens: 2_048) == 4_000
  end

  test "tool result limit is a third of the prompt budget unless configured" do
    Application.put_env(:llm, :context_size, 32_768)
    Application.put_env(:llm, :max_tokens, 4_096)
    assert Budget.tool_result_char_limit() == div(77_016, 3)

    Application.put_env(:llm, :tool_result_max_chars, 5_000)
    assert Budget.tool_result_char_limit() == 5_000
  end

  test "truncate keeps short text and marks cut text" do
    assert Budget.truncate("short", 10) == "short"

    cut = Budget.truncate(String.duplicate("a", 50), 20)

    assert String.starts_with?(
             cut,
             String.duplicate("a", 20) <> "\n\n[truncated 30 of 50 characters"
           )

    refute String.contains?(cut, String.duplicate("a", 21))
  end
end
