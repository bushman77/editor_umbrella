defmodule Llm.Sampling do
  @moduledoc """
  Single source for default sampling settings.

  Profiles in `config/llama.exs` set `sampling: [temperature: ..., ...]`.
  Older config used flat keys (`config :llm, temperature: 0.7`); a flat key,
  when present, wins over the profile's `sampling` list.
  """

  @keys [:temperature, :top_p, :top_k, :min_p, :presence_penalty, :frequency_penalty]

  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc "The configured default for one sampling key, or nil."
  @spec value(atom()) :: term() | nil
  def value(key) when is_atom(key) do
    case Application.fetch_env(:llm, key) do
      {:ok, value} when not is_nil(value) ->
        value

      _other ->
        :llm
        |> Application.get_env(:sampling, [])
        |> Keyword.get(key)
    end
  end
end
