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

  test "build_context includes explicit related files as supporting context" do
    root_path = Path.join(System.tmp_dir!(), "llm-related-context-test-#{System.unique_integer()}")
    primary_path = Path.join([root_path, "lib", "primary.ex"])
    related_path = Path.join([root_path, "lib", "related.ex"])

    File.mkdir_p!(Path.dirname(primary_path))

    File.write!(
      primary_path,
      "defmodule Sample.Primary do\n  def call, do: Sample.Related.value()\nend\n"
    )

    File.write!(
      related_path,
      "defmodule Sample.Related do\n  def value, do: :related_context_marker\nend\n"
    )

    on_exit(fn -> File.rm_rf!(root_path) end)

    assert {:ok, context} =
             Llm.build_context(root_path, primary_path, "What does this use?",
               related_files: [related_path]
             )

    assert Enum.any?(context.files, &(&1.path == "lib/related.ex"))

    prompt =
      context.messages
      |> Enum.map(& &1.content)
      |> Enum.join("\n")

    assert prompt =~ "related_context_marker"
  end

  test "build_context includes source-grounding instructions" do
    root_path = Path.join(System.tmp_dir!(), "llm-grounding-context-test-#{System.unique_integer()}")
    file_path = Path.join([root_path, "lib", "sample.ex"])

    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, "defmodule Sample do\n  def value, do: :ok\nend\n")

    on_exit(fn -> File.rm_rf!(root_path) end)

    assert {:ok, context} = Llm.build_context(root_path, file_path, "Where is current_user?")

    system_prompt =
      context.messages
      |> Enum.filter(&(&1.role == "system"))
      |> Enum.map(& &1.content)
      |> Enum.join("\n")

    assert system_prompt =~ "name the specific file paths"
    assert system_prompt =~ "Do not invent application names"
    assert system_prompt =~ "not present in the provided context"
    assert system_prompt =~ "Do not treat Phoenix Presence metadata"
  end

  test "review questions identify the selected current file" do
    root_path = Path.join(System.tmp_dir!(), "llm-review-context-test-#{System.unique_integer()}")
    file_path = Path.join([root_path, "lib", "sample.ex"])

    File.mkdir_p!(Path.dirname(file_path))
    File.write!(file_path, "defmodule Sample do\n  def value, do: :ok\nend\n")

    on_exit(fn -> File.rm_rf!(root_path) end)

    assert {:ok, context} = Llm.build_context(root_path, file_path, "Can you review this file for me please?")

    system_prompt =
      context.messages
      |> Enum.filter(&(&1.role == "system"))
      |> Enum.map(& &1.content)
      |> Enum.join("\n")

    assert system_prompt =~ "Current file selected in the editor:\nlib/sample.ex"
    assert system_prompt =~ "The user is asking you to review the current file: lib/sample.ex"
    assert system_prompt =~ "Do not ask which file to review."
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

  test "auth-related retrieval includes session and current user files" do
    root_path = Path.join(System.tmp_dir!(), "llm-auth-context-test-#{System.unique_integer()}")

    File.mkdir_p!(Path.join(root_path, "lib/app_web/live"))
    File.mkdir_p!(Path.join(root_path, "lib/app_web"))

    File.write!(
      Path.join(root_path, "lib/app_web/live/lobby_live.ex"),
      """
      defmodule AppWeb.LobbyLive do
        alias AppWeb.Presence
        def mount(_params, _session, socket), do: {:ok, socket}
      end
      """
    )

    File.write!(
      Path.join(root_path, "lib/app_web/user_auth.ex"),
      """
      defmodule AppWeb.UserAuth do
        def fetch_current_user(conn, _opts), do: assign(conn, :current_user, conn.assigns[:user])
      end
      """
    )

    on_exit(fn -> File.rm_rf!(root_path) end)

    assert {:ok, memory} = Llm.ProjectMemory.Builder.build(root_path)

    refs =
      Llm.ContextPack.Builder.retrieve_refs(
        memory,
        "How do we access the user who logged in object from Phoenix Presence?",
        "lib/app_web/live/lobby_live.ex"
      )

    assert Enum.any?(refs, &(&1.path == "lib/app_web/user_auth.ex"))
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
