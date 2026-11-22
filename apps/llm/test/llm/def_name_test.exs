defmodule Llm.DefNameTest do
  use ExUnit.Case, async: true

  @source """
  defmodule Sample do
    def plain(x), do: x

    def guarded(x) when is_map(x) do
      x
    end

    def with_default(x \\\\ 1)
    def with_default(x), do: x

    defp private(x) when is_atom(x), do: x
  end
  """

  test "ContextBuilder records guarded and bodiless public functions by name" do
    functions = Llm.ContextBuilder.analyze_file(@source).public_functions

    assert :plain in functions
    assert :guarded in functions
    assert :with_default in functions
    refute :when in functions
    refute :private in functions
  end

  test "ProjectMemory.Builder records guarded functions by name, not as when" do
    root = Path.join(System.tmp_dir!(), "def-name-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/sample.ex"), @source)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, %{summary: summary}} =
      Llm.ProjectMemory.Builder.build_file(root, Path.join(root, "lib/sample.ex"))

    assert "guarded" in summary.symbols
    assert "plain" in summary.symbols
    refute "when" in summary.symbols
  end
end
