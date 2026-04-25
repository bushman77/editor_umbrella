defmodule LlmTest do
  use ExUnit.Case

  test "stores and returns state" do
    assert Llm.get_state() == %{}

    assert Llm.put(:model, "gpt") == {:ok, %{model: "gpt"}}
    assert Llm.get_state() == %{model: "gpt"}
  end
end
