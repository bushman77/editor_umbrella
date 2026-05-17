defmodule LlmTest do
  use ExUnit.Case

  test "codex genserver starts with empty state" do
    ensure_codex_started()

    assert Llm.Codex.state() == %{}
  end

  test "application only supervises llama server when llm is enabled" do
    original_enabled = Application.get_env(:llm, :enabled, true)

    on_exit(fn ->
      Application.put_env(:llm, :enabled, original_enabled)
    end)

    Application.put_env(:llm, :enabled, false)

    refute Enum.any?(Llm.Application.child_specs(), &match?({Llm.LlamaServer, []}, &1))
    assert Enum.any?(Llm.Application.child_specs(), &match?({Llm.Conversation, []}, &1))
    assert Enum.any?(Llm.Application.child_specs(), &match?({Llm.Codex, []}, &1))

    Application.put_env(:llm, :enabled, true)

    assert Enum.any?(Llm.Application.child_specs(), &match?({Llm.LlamaServer, []}, &1))
  end

  test "public llm api is quiet when llm is disabled" do
    original_enabled = Application.get_env(:llm, :enabled, true)

    on_exit(fn ->
      Application.put_env(:llm, :enabled, original_enabled)
    end)

    Application.put_env(:llm, :enabled, false)

    refute Llm.enabled?()
    refute Llm.ready?()
    assert Llm.status() == %{enabled?: false, ready?: false, reason: :llm_disabled}
    assert Llm.chat("hello") == {:error, :llm_disabled}
  end

  test "llama server model path comes from llm config" do
    original_model = Application.get_env(:llm, :model)
    configured_model = "~/models/test-configured-model.gguf"

    on_exit(fn ->
      if original_model do
        Application.put_env(:llm, :model, original_model)
      else
        Application.delete_env(:llm, :model)
      end
    end)

    Application.put_env(:llm, :model, configured_model)

    assert Llm.LlamaServer.model_path() == Path.expand(configured_model)
  end

  test "llama server base url comes from llm host and port config" do
    original_host = Application.get_env(:llm, :host)
    original_port = Application.get_env(:llm, :port)

    on_exit(fn ->
      restore_llm_env(:host, original_host)
      restore_llm_env(:port, original_port)
    end)

    Application.put_env(:llm, :host, "0.0.0.0")
    Application.put_env(:llm, :port, 9999)

    assert Llm.LlamaServer.base_url() == "http://0.0.0.0:9999"
  end

  test "conversation lists snapshots for a project newest first" do
    ensure_conversation_started()

    project_id = "project-list-test-#{System.unique_integer([:positive])}"
    other_project_id = "project-list-other-#{System.unique_integer([:positive])}"

    first_id = Llm.Conversation.new_id(project_id)
    second_id = Llm.Conversation.new_id(project_id)
    other_id = Llm.Conversation.new_id(other_project_id)

    Llm.Conversation.record_turn(first_id, "Older question?", nil,
      project_id: project_id,
      current_file: "lib/older.ex"
    )

    Process.sleep(2)

    Llm.Conversation.record_turn(second_id, "Newer question?", nil,
      project_id: project_id,
      current_file: "lib/newer.ex"
    )

    Llm.Conversation.record_turn(other_id, "Other project?", nil,
      project_id: other_project_id,
      current_file: "lib/other.ex"
    )

    assert Enum.map(Llm.Conversation.list_for_project(project_id), & &1.id) == [
             second_id,
             first_id
           ]

    assert Enum.map(Llm.Conversation.list_for_project(project_id, 1), & &1.id) == [
             second_id
           ]
  end

  defp restore_llm_env(key, nil), do: Application.delete_env(:llm, key)
  defp restore_llm_env(key, value), do: Application.put_env(:llm, key, value)

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

  test "build_context uses related file specs without injecting related file bodies" do
    root_path =
      Path.join(System.tmp_dir!(), "llm-related-context-test-#{System.unique_integer()}")

    primary_path = Path.join([root_path, "lib", "primary.ex"])
    related_path = Path.join([root_path, "lib", "related.ex"])

    File.mkdir_p!(Path.dirname(primary_path))

    File.write!(
      primary_path,
      "defmodule Sample.Primary do\n  def call, do: Sample.Related.value()\nend\n"
    )

    File.write!(
      related_path,
      """
      defmodule Sample.Related do
        @spec value() :: atom()
        def value, do: :related_context_marker
      end
      """
    )

    on_exit(fn -> File.rm_rf!(root_path) end)

    assert {:ok, context} =
             Llm.build_context(root_path, primary_path, "What does this use?",
               related_file_specs: [
                 %{
                   path: related_path,
                   relationship: "uses",
                   included?: true,
                   functions: [
                     %{
                       name: "value",
                       spec: "@spec value() :: atom()",
                       head: "def value, do: :related_context_marker",
                       start_line: 3,
                       end_line: 3
                     }
                   ]
                 }
               ]
             )

    prompt =
      context.messages
      |> Enum.map(& &1.content)
      |> Enum.join("\n")

    assert prompt =~ "lib/related.ex | relationship: uses"
    assert prompt =~ "@spec value() :: atom()"
    refute prompt =~ "related_context_marker"
  end

  test "build_context includes open files as supporting workspace context" do
    root_path =
      Path.join(System.tmp_dir!(), "llm-open-files-context-test-#{System.unique_integer()}")

    selected_path = Path.join([root_path, "lib", "selected.ex"])
    open_path = Path.join([root_path, "lib", "open_tab.ex"])

    File.mkdir_p!(Path.dirname(selected_path))

    File.write!(
      selected_path,
      "defmodule Sample.Selected do\n  def value, do: :selected_context_marker\nend\n"
    )

    File.write!(
      open_path,
      """
      defmodule Sample.OpenTab do
        def first_value, do: :open_tab_context_marker

        def second_value do
          :second_open_tab_context_marker
        end
      end
      """
    )

    on_exit(fn -> File.rm_rf!(root_path) end)

    assert {:ok, context} =
             Llm.build_context(root_path, selected_path, "How do these files relate?",
               open_files: [open_path]
             )

    assert "lib/selected.ex" in Llm.ContextPack.referenced_paths(context.pack)
    assert "lib/open_tab.ex" in Llm.ContextPack.referenced_paths(context.pack)

    assert Enum.any?(context.pack.refs, fn ref ->
             ref.path == "lib/open_tab.ex" and ref.metadata[:source] == :open_file
           end)

    prompt =
      context.messages
      |> Enum.map(& &1.content)
      |> Enum.join("\n")

    assert prompt =~ "selected_context_marker"
    assert prompt =~ "open_tab_context_marker"
    assert prompt =~ "second_open_tab_context_marker"
    assert prompt =~ "SOURCE: open file supporting context"
  end

  test "context builder extracts function ranges from a file" do
    root_path = Path.join(System.tmp_dir!(), "llm-function-range-test-#{System.unique_integer()}")
    file_path = Path.join(root_path, "lib/sample.ex")

    File.mkdir_p!(Path.dirname(file_path))

    File.write!(file_path, """
    defmodule Sample do
      @doc "Runs the thing"
      @spec run(term()) :: term()
      def run(value) when is_binary(value) do
        String.upcase(value)
      end

      defp normalize(value) do
        String.trim(value)
      end
    end
    """)

    on_exit(fn -> File.rm_rf!(root_path) end)

    assert [
             %{
               kind: "def",
               name: "run",
               spec: "@spec run(term()) :: term()",
               head: "def run(value) when is_binary(value) do",
               start_line: 2,
               end_line: 6,
               matches: []
             },
             %{
               kind: "defp",
               name: "normalize",
               spec: nil,
               head: "defp normalize(value) do",
               start_line: 8,
               end_line: 10,
               matches: []
             }
           ] = Llm.ContextBuilder.extract_function(file_path)
  end

  test "context builder extracts functions containing ripgrep matches" do
    root_path = Path.join(System.tmp_dir!(), "llm-function-match-test-#{System.unique_integer()}")
    file_path = Path.join(root_path, "lib/sample.ex")

    File.mkdir_p!(Path.dirname(file_path))

    File.write!(file_path, """
    defmodule Sample do
      def run(value) do
        String.upcase(value)
      end

      defp normalize(value) do
        String.trim(value)
      end
    end
    """)

    on_exit(fn -> File.rm_rf!(root_path) end)

    assert [
             %{
               name: "normalize",
               matches: [7],
               content: content
             }
           ] = Llm.ContextBuilder.extract_function(file_path, "String.trim")

    assert content =~ "defp normalize"
    refute content =~ "def run"
  end

  test "rag build_context is the editor-aware retrieval boundary" do
    root_path = Path.join(System.tmp_dir!(), "llm-rag-context-test-#{System.unique_integer()}")
    selected_path = Path.join([root_path, "lib", "selected.ex"])

    File.mkdir_p!(Path.dirname(selected_path))

    File.write!(
      selected_path,
      "defmodule Sample.Selected do\n  def value, do: :rag_context_marker\nend\n"
    )

    on_exit(fn -> File.rm_rf!(root_path) end)

    assert {:ok, context} = Llm.Rag.build_context(root_path, selected_path, "What does this do?")

    assert context.mode == :file
    assert context.root_path == Path.expand(root_path)
    assert context.primary_path == selected_path
    assert context.pack.current_file == "lib/selected.ex"
    assert Enum.any?(context.files, &(&1.path == "lib/selected.ex"))

    prompt =
      context.messages
      |> Enum.map(& &1.content)
      |> Enum.join("\n")

    assert prompt =~ "rag_context_marker"
  end

  test "conversation records user turns without assistant answers by default" do
    ensure_conversation_started()
    conversation_id = Llm.Conversation.new_id("project-a")

    assert %{messages: []} = Llm.Conversation.ensure(conversation_id, project_id: "project-a")

    Llm.Conversation.record_turn(conversation_id, "Question one?", "Answer one.")
    snapshot = Llm.Conversation.record_turn(conversation_id, "Question two?", "Answer two.")

    assert snapshot.project_id == "project-a"

    assert Llm.Conversation.recent_messages(conversation_id, 2) == [
             %{role: "user", content: "Question one?"},
             %{role: "user", content: "Question two?"}
           ]

    assert Llm.Conversation.summary(conversation_id) == nil
  end

  test "conversation can explicitly retain assistant answers" do
    ensure_conversation_started()
    conversation_id = Llm.Conversation.new_id("project-b")

    Llm.Conversation.record_turn(conversation_id, "Question?", "Answer.", store_assistant?: true)

    assert Llm.Conversation.recent_messages(conversation_id, 2) == [
             %{role: "user", content: "Question?"}
           ]

    assert Llm.Conversation.recent_messages(conversation_id, 2, include_assistant?: true) == [
             %{role: "user", content: "Question?"},
             %{role: "assistant", content: "Answer."}
           ]
  end

  test "conversation records user turn when assistant answer is nil" do
    ensure_conversation_started()

    project_id = "project-nil-answer-#{System.unique_integer([:positive])}"
    conversation_id = Llm.Conversation.new_id(project_id)

    Llm.Conversation.delete(conversation_id)

    snapshot =
      Llm.Conversation.record_turn(conversation_id, "Question?", nil,
        project_id: project_id,
        current_file: "lib/example.ex"
      )

    assert snapshot.messages == [%{role: "user", content: "Question?"}]
  end

  test "build_context includes recent conversation messages when provided" do
    root_path = Path.join(System.tmp_dir!(), "llm-recent-context-test-#{System.unique_integer()}")
    selected_path = Path.join([root_path, "lib", "selected.ex"])

    File.mkdir_p!(Path.dirname(selected_path))
    File.write!(selected_path, "defmodule Sample.Selected do\n  def value, do: :ok\nend\n")

    on_exit(fn -> File.rm_rf!(root_path) end)

    recent_messages = [
      %{role: "user", content: "Earlier question marker"},
      %{role: "assistant", content: "Earlier answer marker"}
    ]

    assert {:ok, context} =
             Llm.build_context(root_path, selected_path, "What now?",
               recent_messages: recent_messages,
               conversation_summary: "Conversation summary marker",
               conversation_id: "conversation-test"
             )

    prompt =
      context.messages
      |> Enum.map(& &1.content)
      |> Enum.join("\n")

    assert context.pack.conversation_id == "conversation-test"
    assert prompt =~ "Earlier question marker"
    assert prompt =~ "Earlier answer marker"
    assert prompt =~ "Conversation summary marker"
  end

  test "context pack trims retrieved refs to stay within the token budget" do
    memory =
      Llm.ProjectMemory.new_snapshot(project_id: "budget-test")
      |> Llm.ProjectMemory.put_file_summary(
        Llm.ProjectMemory.FileSummary.from_file("lib/current.ex",
          summary: "Current file",
          sha256: "current"
        )
      )
      |> Llm.ProjectMemory.put_file_chunk(
        Llm.ProjectMemory.FileChunk.new(
          path: "lib/current.ex",
          chunk_index: 0,
          start_line: 1,
          end_line: 10,
          content: String.duplicate("current ", 200),
          sha256: "current"
        )
      )

    memory =
      Enum.reduce(1..8, memory, fn index, memory ->
        path = "lib/support_#{index}.ex"

        memory
        |> Llm.ProjectMemory.put_file_summary(
          Llm.ProjectMemory.FileSummary.from_file(path,
            summary: "Support file #{index}",
            sha256: "support-#{index}"
          )
        )
        |> Llm.ProjectMemory.put_file_chunk(
          Llm.ProjectMemory.FileChunk.new(
            path: path,
            chunk_index: 0,
            start_line: 1,
            end_line: 80,
            content: String.duplicate("support #{index} ", 500),
            sha256: "support-#{index}"
          )
        )
      end)

    pack =
      Llm.ContextPack.Builder.build(memory, %{
        question: "What does this do?",
        current_file: "lib/current.ex",
        token_budget: 2_500
      })

    assert pack.estimated_tokens <= 2_500
    assert "lib/current.ex" in Llm.ContextPack.referenced_paths(pack)
    assert Llm.ContextPack.ref_count(pack) < map_size(memory.files) * 2
  end

  test "project memory chunks Elixir files by complete functions" do
    root_path = Path.join(System.tmp_dir!(), "llm-function-chunk-test-#{System.unique_integer()}")
    file_path = Path.join([root_path, "lib", "sample.ex"])

    File.mkdir_p!(Path.dirname(file_path))

    File.write!(
      file_path,
      """
      defmodule Sample do
        @impl true
        def handle_info(%{event: "presence_diff"}, socket) do
          users = Presence.list(@topic)

          socket =
            assign(socket, users: users)

          {:noreply, socket}
        end

        def unrelated(socket) do
          {:noreply, socket}
        end
      end
      """
    )

    on_exit(fn -> File.rm_rf!(root_path) end)

    assert {:ok, %{chunks: chunks}} = Llm.ProjectMemory.Builder.build_file(root_path, file_path)

    handle_info_chunk =
      Enum.find(chunks, fn chunk ->
        String.contains?(chunk.content, "def handle_info")
      end)

    assert handle_info_chunk.metadata.chunk_strategy == :function
    assert handle_info_chunk.content =~ "@impl true"
    assert handle_info_chunk.content =~ "users = Presence.list(@topic)"
    assert handle_info_chunk.content =~ "{:noreply, socket}"
    refute handle_info_chunk.content =~ "def unrelated"
  end

  test "build_context includes source-grounding instructions" do
    root_path =
      Path.join(System.tmp_dir!(), "llm-grounding-context-test-#{System.unique_integer()}")

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

    assert {:ok, context} =
             Llm.build_context(root_path, file_path, "Can you review this file for me please?")

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

  test "related retrieval includes modules referenced by direct remote calls" do
    root_path =
      Path.join(System.tmp_dir!(), "llm-direct-module-context-test-#{System.unique_integer()}")

    source_path = Path.join(root_path, "lib/brain.ex")
    pipeline_path = Path.join(root_path, "lib/brain/pipeline/lifg_stage1.ex")
    stage2_path = Path.join(root_path, "lib/brain/lifg/stage2.ex")

    File.mkdir_p!(Path.dirname(source_path))
    File.mkdir_p!(Path.dirname(pipeline_path))
    File.mkdir_p!(Path.dirname(stage2_path))

    File.write!(source_path, """
    defmodule Brain do
      def lifg_stage1(si, vec, opts) do
        Brain.Pipeline.LIFGStage1.run(si, vec, opts, %{})
      end

      def gate_from_lifg(si, opts) do
        Brain.LIFG.Stage2.run(si, opts)
      end
    end
    """)

    File.write!(pipeline_path, """
    defmodule Brain.Pipeline.LIFGStage1 do
      def run(si, vec, opts, state), do: {si, vec, opts, state}
    end
    """)

    File.write!(stage2_path, """
    defmodule Brain.LIFG.Stage2 do
      def run(si, opts), do: {:ok, %{si: si, opts: opts}}
    end
    """)

    on_exit(fn -> File.rm_rf!(root_path) end)

    related_paths =
      Llm.ContextBuilder.related_file_paths_for_refactor(
        source_path,
        File.read!(source_path),
        "",
        root_path
      )

    assert pipeline_path in related_paths
    assert stage2_path in related_paths
  end

  test "auth-related retrieval includes session and current user files" do
    root_path = Path.join(System.tmp_dir!(), "llm-auth-context-test-#{System.unique_integer()}")

    File.mkdir_p!(Path.join(root_path, "lib/app_web/live"))
    File.mkdir_p!(Path.join(root_path, "lib/app_web"))

    File.write!(
      Path.join(root_path, "lib/app_web/live/session_live.ex"),
      """
      defmodule AppWeb.SessionLive do
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
        "lib/app_web/live/session_live.ex"
      )

    assert Enum.any?(refs, &(&1.path == "lib/app_web/user_auth.ex"))
  end

  test "player join retrieval includes presence producer and subscriber files" do
    root_path =
      Path.join(System.tmp_dir!(), "llm-player-join-context-test-#{System.unique_integer()}")

    File.mkdir_p!(Path.join(root_path, "lib/app_web/live"))
    File.mkdir_p!(Path.join(root_path, "lib/app"))

    File.write!(
      Path.join(root_path, "lib/app_web/live/room_live.ex"),
      """
      defmodule AppWeb.RoomLive do
        alias AppWeb.Presence
        @room_topic "room:main"
        def handle_event("connect", _params, socket) do
          Presence.track(self(), @room_topic, "player", %{name: "Player"})
          {:noreply, socket}
        end
        def handle_info(%{event: "presence_diff"}, socket) do
          users = Presence.list(@room_topic)
          {:noreply, assign(socket, users: users)}
        end
      end
      """
    )

    File.write!(
      Path.join(root_path, "lib/app/player_watcher.ex"),
      """
      defmodule App.PlayerWatcher do
        use GenServer
        alias Phoenix.PubSub
        @room_topic "room:main"
        def init(state) do
          PubSub.subscribe(App.PubSub, @room_topic)
          {:ok, state}
        end
        def handle_info(%{event: "presence_diff"}, state), do: {:noreply, state}
      end
      """
    )

    on_exit(fn -> File.rm_rf!(root_path) end)

    assert {:ok, memory} = Llm.ProjectMemory.Builder.build(root_path)

    refs =
      Llm.ContextPack.Builder.retrieve_refs(
        memory,
        "How can we have our Llm be notified when a new player joins?",
        "lib/app_web/live/room_live.ex"
      )

    assert Enum.any?(refs, &(&1.path == "lib/app_web/live/room_live.ex"))
    assert Enum.any?(refs, &(&1.path == "lib/app/player_watcher.ex"))
  end

  test "implementation questions warn against invented or unreachable existing code" do
    memory = Llm.ProjectMemory.new_snapshot(project_id: "implementation-contract-test")

    pack =
      Llm.ContextPack.Builder.build(memory, %{
        question: "How can we have our Llm be notified when a new player joins?",
        current_file: "lib/app_web/live/room_live.ex"
      })

    system_prompt =
      pack.messages
      |> Enum.filter(&(&1.role == "system"))
      |> Enum.map(& &1.content)
      |> Enum.join("\n")

    assert system_prompt =~ "Distinguish existing code from proposed code"
    assert system_prompt =~ "verify it appears in the provided snippets"
    assert system_prompt =~ "Code after a returned `{:noreply, ...}`"
    assert system_prompt =~ "Do not add or call new notification APIs"
    assert system_prompt =~ "label it as a new function to add"

    assert system_prompt =~
             "Do not answer PubSub/event wiring questions by adding a standalone helper"

    assert system_prompt =~
             "Identify the existing event producer and the existing subscriber/consumer"

    assert system_prompt =~ "If either side is missing from snippets"
    assert system_prompt =~ "observed join/presence/event boundary"
    assert system_prompt =~ "Do not put the change in an unrelated module"

    assert system_prompt =~
             "Do not put application business logic inside modules that `use Phoenix.Presence`"

    assert system_prompt =~ "Do not suggest changing a module's role"
    assert system_prompt =~ "prefer existing PubSub subscribers"
    assert system_prompt =~ "existing `%{event: \"presence_diff\"}` handlers"
    assert system_prompt =~ "Do not override framework/library callback wrappers"
    assert system_prompt =~ "Do not suggest adding a sibling OTP application module"
    assert system_prompt =~ "Do not call callback functions such as `handle_info/2` directly"
    assert system_prompt =~ "Never regenerate or copy an entire existing module"
    assert system_prompt =~ "Do not include unchanged existing functions in code blocks"
    assert system_prompt =~ "Do not start a code block with `defmodule`"
    assert system_prompt =~ "A response that wraps a change in the existing module is invalid"
    assert system_prompt =~ "If more than three functions would change"
    assert system_prompt =~ "Use this response shape for implementation requests"
    assert system_prompt =~ "Existing evidence:"
    assert system_prompt =~ "Never use placeholder comments"
    assert system_prompt =~ "every new function must have a visible caller or call-site change"
    assert system_prompt =~ "No patch from provided context"
    assert system_prompt =~ "Final answer rules for this implementation guidance request"
    assert system_prompt =~ "Keep the entire answer under 500 words"
    assert system_prompt =~ "Do not include any code block"
    assert system_prompt =~ "Do not output a complete module or complete file"
    assert system_prompt =~ "Do not invent config, routes, supervision, PubSub topics"
    assert system_prompt =~ "Give file/function direction only"
    assert system_prompt =~ "this is guidance, not a patch"
  end

  test "refactor prompts do not include implementation refusal contract" do
    memory = Llm.ProjectMemory.new_snapshot(project_id: "refactor-contract-test")

    pack =
      Llm.ContextPack.Builder.build(memory, %{
        question: "Please refactor apps/core/lib/core.ex",
        current_file: "apps/core/lib/core.ex"
      })

    system_prompt =
      pack.messages
      |> Enum.filter(&(&1.role == "system"))
      |> Enum.map(& &1.content)
      |> Enum.join("\n")

    assert system_prompt =~ "Refactor output contract"

    assert system_prompt =~
             "Do not refuse because a supporting snippet has unknown or partial line ranges"

    refute system_prompt =~ "Implementation request contract"
    refute system_prompt =~ "No patch from provided context"
  end

  test "related file specs are attached to the prompt as relationship objects" do
    memory = Llm.ProjectMemory.new_snapshot(project_id: "related-file-specs-test")

    pack =
      Llm.ContextPack.Builder.build(memory, %{
        question: "Refactor this file",
        current_file: "lib/source.ex",
        related_file_specs: [
          %{
            path: "lib/helper.ex",
            relationship: "uses",
            included?: true,
            functions: [
              %{
                name: "call",
                spec: "@spec call(term()) :: :ok",
                head: "def call(value) do",
                start_line: 12,
                end_line: 18
              }
            ]
          }
        ]
      })

    system_prompt =
      pack.messages
      |> Enum.filter(&(&1.role == "system"))
      |> Enum.map(& &1.content)
      |> Enum.join("\n")

    assert system_prompt =~ "Opened file and attached related objects"
    assert system_prompt =~ "Opened file: lib/source.ex"
    assert system_prompt =~ "lib/helper.ex | relationship: uses"
    assert system_prompt =~ "call (@spec call(term()) :: :ok, lines 12-18)"

    assert pack.metadata.related_file_specs == [
             %{
               path: "lib/helper.ex",
               relationship: "uses",
               included?: true,
               functions: [
                 %{
                   name: "call",
                   spec: "@spec call(term()) :: :ok",
                   head: "def call(value) do",
                   start_line: 12,
                   end_line: 18
                 }
               ]
             }
           ]
  end

  test "public app functions have specs or behaviour callback implementations" do
    root_path = Path.expand("../../..", __DIR__)
    callback_names = MapSet.new(~w(
      config_change
      handle_async
      handle_call
      handle_cast
      handle_continue
      handle_event
      handle_info
      init
      mount
      render
      start
    )a)

    missing_specs =
      root_path
      |> Path.join("apps/*/lib/**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        lines = file |> File.read!() |> String.split("\n")

        specs =
          lines
          |> Enum.flat_map(fn line ->
            case Regex.run(~r/^  @spec\s+([a-zA-Z_][\w!?]*)/, line) do
              [_, name] -> [String.to_atom(name)]
              _ -> []
            end
          end)
          |> MapSet.new()

        lines
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, line_number} ->
          case Regex.run(~r/^  def(?:macro)?\s+([a-zA-Z_][\w!?]*)/, line) do
            [_, name] ->
              name = String.to_atom(name)

              if MapSet.member?(specs, name) or MapSet.member?(callback_names, name) do
                []
              else
                ["#{Path.relative_to(file, root_path)}:#{line_number} #{String.trim(line)}"]
              end

            _ ->
              []
          end
        end)
      end)
      |> Enum.uniq()

    assert missing_specs == []
  end

  test "implementation final answer contract is adjacent to the user question" do
    memory = Llm.ProjectMemory.new_snapshot(project_id: "implementation-final-contract-test")

    pack =
      Llm.ContextPack.Builder.build(memory, %{
        question: "How can we have our Llm be notified when a new player joins? PubSub",
        current_file: "lib/app_web/live/room_live.ex"
      })

    messages = pack.messages
    user_index = Enum.find_index(messages, &(&1.role == "user"))
    final_contract = Enum.at(messages, user_index - 1)

    assert final_contract.role == "system"
    assert final_contract.content =~ "Final answer rules for this implementation guidance request"
    assert final_contract.content =~ "Do not output a complete module or complete file"
    assert final_contract.content =~ "Do not include any code block"
  end

  test "explicit patch requests keep patch-mode final answer contract" do
    memory = Llm.ProjectMemory.new_snapshot(project_id: "implementation-patch-contract-test")

    pack =
      Llm.ContextPack.Builder.build(memory, %{
        question: "How can we have our Llm be notified when a new player joins? Show code.",
        current_file: "lib/app_web/live/room_live.ex"
      })

    messages = pack.messages
    user_index = Enum.find_index(messages, &(&1.role == "user"))
    final_contract = Enum.at(messages, user_index - 1)

    assert final_contract.role == "system"
    assert final_contract.content =~ "Final answer rules for this implementation request"
    assert final_contract.content =~ "Do not start any code block with `defmodule`"
    assert final_contract.content =~ "capped at 60 lines total"
  end

  test "broadcasting and inclusion phrasing gets implementation guidance" do
    memory = Llm.ProjectMemory.new_snapshot(project_id: "broadcasting-contract-test")

    pack =
      Llm.ContextPack.Builder.build(memory, %{
        question:
          "I think this file needs to be included with having our LiveView broadcasting somewhere?",
        current_file: "lib/app_web/live/room_live.ex"
      })

    system_prompt =
      pack.messages
      |> Enum.filter(&(&1.role == "system"))
      |> Enum.map(& &1.content)
      |> Enum.join("\n")

    assert system_prompt =~ "Implementation request contract"
    assert system_prompt =~ "Do not suggest adding a sibling OTP application module"
    assert system_prompt =~ "Do not call callback functions such as `handle_info/2` directly"
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

  defp ensure_conversation_started do
    unless Process.whereis(Llm.Conversation) do
      start_supervised!({Llm.Conversation, []})
    end
  end

  defp ensure_codex_started do
    unless Process.whereis(Llm.Codex) do
      start_supervised!({Llm.Codex, []})
    end
  end
end
