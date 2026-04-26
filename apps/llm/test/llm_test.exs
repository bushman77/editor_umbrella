defmodule LlmTest do
  use ExUnit.Case

  test "folder prompts include project paths without file contents" do
    root_path = Path.join(System.tmp_dir!(), "llm-prompt-test-#{System.unique_integer()}")
    nested_path = Path.join([root_path, "lib", "sample.ex"])

    File.mkdir_p!(Path.dirname(nested_path))
    File.write!(nested_path, "defmodule Sample do\n  def secret, do: :do_not_prompt\nend\n")
    on_exit(fn -> File.rm_rf!(root_path) end)

    assert [
             %{role: "system"},
             %{role: "user", content: prompt}
           ] = Llm.Prompts.editor_folder_question(root_path, "What files are here?")

    assert prompt =~ "Project files:"
    assert prompt =~ "lib/sample.ex"
    refute prompt =~ "defmodule Sample"
    refute prompt =~ "do_not_prompt"
  end

  test "file question prompts use a smaller content budget" do
    content = String.duplicate("a", 6_100) <> "tail"

    assert [
             %{role: "system"},
             %{role: "user", content: prompt}
           ] = Llm.Prompts.editor_file_question("sample.ex", content, "What does this do?")

    assert prompt =~ "[Truncated before sending to the model.]"
    refute prompt =~ "tail"
  end

  test "file refactor prompts keep the larger content budget" do
    content = String.duplicate("a", 6_100) <> "tail"

    assert [
             %{role: "system"},
             %{role: "user", content: prompt}
           ] = Llm.Prompts.editor_file_question("sample.ex", content, "Please refactor this file")

    refute prompt =~ "[Truncated before sending to the model.]"
    assert prompt =~ "tail"
  end

  test "prompt stats report totals and role breakdowns" do
    messages = [
      %{role: "system", content: "abcd"},
      %{role: "user", content: "abcde"},
      %{role: "user", content: "abc"}
    ]

    assert Llm.Prompts.stats(messages) == %{
             message_count: 3,
             total_chars: 12,
             estimated_tokens: 3,
             by_role: %{
               "system" => %{message_count: 1, chars: 4, estimated_tokens: 1},
               "user" => %{message_count: 2, chars: 8, estimated_tokens: 2}
             }
           }
  end

  test "test-related retrieval includes associated test files" do
    root_path = Path.join(System.tmp_dir!(), "llm-context-test-#{System.unique_integer()}")

    File.mkdir_p!(Path.join(root_path, "lib/llm"))
    File.mkdir_p!(Path.join(root_path, "test"))

    File.write!(
      Path.join(root_path, "lib/llm/llama_server.ex"),
      "defmodule Llm.LlamaServer do\n  def ready?, do: true\nend\n"
    )

    File.write!(
      Path.join(root_path, "lib/llm/client.ex"),
      "defmodule Llm.Client do\n  def chat, do: :ok\nend\n"
    )

    File.write!(
      Path.join(root_path, "test/llm_test.exs"),
      "defmodule LlmTest do\n  use ExUnit.Case\n  test \"ready\" do\n    assert true\n  end\nend\n"
    )

    on_exit(fn -> File.rm_rf!(root_path) end)

    assert {:ok, memory} = Llm.ProjectMemory.Builder.build(root_path)

    refs =
      Llm.ContextPack.Builder.retrieve_refs(
        memory,
        "What unit tests are associated with this file?",
        "lib/llm/llama_server.ex"
      )

    assert Enum.any?(refs, &(&1.path == "test/llm_test.exs"))
    refute Enum.any?(refs, &(&1.path == "lib/llm/client.ex"))
  end

  test "non-test retrieval keeps same-directory refs without test fallback files" do
    root_path = Path.join(System.tmp_dir!(), "llm-context-test-#{System.unique_integer()}")

    File.mkdir_p!(Path.join(root_path, "lib/llm"))
    File.mkdir_p!(Path.join(root_path, "test"))

    File.write!(
      Path.join(root_path, "lib/llm/llama_server.ex"),
      "defmodule Llm.LlamaServer do\n  def ready?, do: true\nend\n"
    )

    File.write!(
      Path.join(root_path, "lib/llm/client.ex"),
      "defmodule Llm.Client do\n  def chat, do: :ok\nend\n"
    )

    File.write!(
      Path.join(root_path, "test/llm_test.exs"),
      "defmodule LlmTest do\n  use ExUnit.Case\nend\n"
    )

    on_exit(fn -> File.rm_rf!(root_path) end)

    assert {:ok, memory} = Llm.ProjectMemory.Builder.build(root_path)

    refs =
      Llm.ContextPack.Builder.retrieve_refs(
        memory,
        "What does this file do?",
        "lib/llm/llama_server.ex"
      )

    refute Enum.any?(refs, &(&1.path == "test/llm_test.exs"))
    assert Enum.any?(refs, &(&1.path == "lib/llm/client.ex"))
  end

  test "test retrieval does not trigger on unrelated words containing test" do
    root_path = Path.join(System.tmp_dir!(), "llm-context-test-#{System.unique_integer()}")

    File.mkdir_p!(Path.join(root_path, "lib/llm"))
    File.mkdir_p!(Path.join(root_path, "test"))

    File.write!(
      Path.join(root_path, "lib/llm/llama_server.ex"),
      "defmodule Llm.LlamaServer do\n  def ready?, do: true\nend\n"
    )

    File.write!(
      Path.join(root_path, "test/llm_test.exs"),
      "defmodule LlmTest do\n  use ExUnit.Case\nend\n"
    )

    on_exit(fn -> File.rm_rf!(root_path) end)

    assert {:ok, memory} = Llm.ProjectMemory.Builder.build(root_path)

    refs =
      Llm.ContextPack.Builder.retrieve_refs(
        memory,
        "What is the latest behavior in this file?",
        "lib/llm/llama_server.ex"
      )

    refute Enum.any?(refs, &(&1.path == "test/llm_test.exs"))
  end
end
