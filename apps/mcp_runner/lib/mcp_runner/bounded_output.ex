defmodule McpRunner.BoundedOutput do
  @moduledoc """
  A bounded Collectable for stdout/stderr from developer commands.

  System.cmd/3 drains all output, but retains at most the configured number
  of bytes, preventing noisy processes from accumulating unbounded binaries.
  """

  defstruct data: "", limit: 0, truncated: false

  @type t :: %__MODULE__{data: binary(), limit: non_neg_integer(), truncated: boolean()}

  @spec new(non_neg_integer()) :: t()
  def new(limit) when is_integer(limit) and limit >= 0 do
    %__MODULE__{limit: limit}
  end

  @doc false
  @spec append(t(), binary()) :: t()
  def append(%__MODULE__{truncated: true} = state, _chunk), do: state

  def append(%__MODULE__{data: data, limit: limit} = state, chunk) when is_binary(chunk) do
    remaining = max(limit - byte_size(data), 0)

    if byte_size(chunk) <= remaining do
      %{state | data: data <> chunk}
    else
      %{state | data: data <> binary_part(chunk, 0, remaining), truncated: true}
    end
  end

  @spec text(t()) :: String.t()
  def text(%__MODULE__{data: data, truncated: truncated}) do
    suffix = if truncated, do: "\n[Output truncated]", else: ""
    String.replace_invalid(data) <> suffix
  end
end

defimpl Collectable, for: McpRunner.BoundedOutput do
  @spec into(McpRunner.BoundedOutput.t()) :: {McpRunner.BoundedOutput.t(), function()}
  def into(initial) do
    {initial,
     fn
       acc, {:cont, chunk} -> McpRunner.BoundedOutput.append(acc, chunk)
       acc, :done -> acc
       _acc, :halt -> :ok
     end}
  end
end
