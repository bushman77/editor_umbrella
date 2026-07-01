defmodule EditorWeb.EditorLiveTest do
  use EditorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "llm async request payload keeps open-file context" do
    source_file = "/workspace/apps/editor_web/lib/editor_web/live/editor_live.ex"
    open_file = "/workspace/apps/editor/lib/editor/open_file_cache.ex"

    assigns = %{
      cwd: "/workspace",
      selected_file: source_file,
      related_files: [],
      related_file_context_overrides: %{},
      llm_conversation_id: "conversation-1",
      cached_open_files: [%{path: open_file}],
      open_tabs: [source_file, open_file],
      large_unrelated_assign: String.duplicate("x", 1_000)
    }

    request_assigns = EditorWeb.EditorLlm.request_assigns(assigns)

    assert request_assigns.cached_open_files == [%{path: open_file}]
    assert request_assigns.open_tabs == [source_file, open_file]
    refute Map.has_key?(request_assigns, :large_unrelated_assign)
  end

  #########################################
  # TESTS 
  #########################################
  @tag :tmp_dir
  test "tracks opened files as switchable tabs", %{conn: conn, tmp_dir: tmp_dir} do
    first_file = Path.join(tmp_dir, "alpha.txt")
    second_file = Path.join(tmp_dir, "beta.txt")

    File.write!(first_file, "alpha")
    File.write!(second_file, "beta")

    {:ok, view, _html} = live(conn, ~p"/")

    open_folder(view, tmp_dir)
    open_file(view, first_file)

    assert has_element?(view, tab_selector(first_file))

    open_file(view, second_file)

    assert has_element?(view, tab_selector(first_file))
    assert has_element?(view, tab_selector(second_file))
    assert has_element?(view, code_editor_selector(second_file))

    view
    |> element(select_tab_selector(first_file))
    |> render_click()

    assert has_element?(view, code_editor_selector(first_file))

    view
    |> element(close_tab_selector(first_file))
    |> render_click()

    refute has_element?(view, tab_selector(first_file))
    assert has_element?(view, tab_selector(second_file))
    assert has_element?(view, code_editor_selector(second_file))
  end

  @tag :tmp_dir
  test "shows related files discovered from aliases across umbrella sibling apps", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    web_app = Path.join([tmp_dir, "apps", "web_app"])
    core_app = Path.join([tmp_dir, "apps", "core_app"])
    source_file = Path.join([web_app, "lib", "source.ex"])
    helper_file = Path.join([core_app, "lib", "helper.ex"])

    File.mkdir_p!(Path.dirname(source_file))
    File.mkdir_p!(Path.dirname(helper_file))
    File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule Umbrella.MixProject do\nend\n")

    File.write!(source_file, """
    defmodule Sample.Source do
      alias Sample.Helper

      def call, do: Helper.call()
    end
    """)

    File.write!(helper_file, """
    defmodule Sample.Helper do
      def call, do: :ok
      defp normalize(value), do: value
    end
    """)

    {:ok, view, _html} = live(conn, ~p"/")

    open_folder(view, web_app)
    open_file_from_tree(view, web_app, source_file)

    view
    |> element("#toggle-related-files-button")
    |> render_click()

    assert has_element?(view, related_file_selector(helper_file))
    assert has_element?(view, related_file_reason_selector(helper_file), "uses")
    assert has_element?(view, related_file_functions_selector(helper_file), "call")
    refute has_element?(view, related_file_functions_selector(helper_file), "normalize")

    view
    |> element(related_file_open_selector(helper_file))
    |> render_click()

    assert has_element?(view, tab_selector(source_file))
    assert has_element?(view, tab_selector(helper_file))
    assert has_element?(view, code_editor_selector(helper_file))
  end

  @tag :tmp_dir
  test "shows all discovered related files for the opened file", %{conn: conn, tmp_dir: tmp_dir} do
    app_root = Path.join([tmp_dir, "apps", "sample_app"])
    source_file = Path.join([app_root, "lib", "source.ex"])
    caller_files = Enum.map(1..17, &Path.join([app_root, "lib", "caller_#{&1}.ex"]))

    File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule TempUmbrella.MixProject do\nend\n")
    File.mkdir_p!(Path.dirname(source_file))

    File.write!(source_file, """
    defmodule Sample.Source do
      def run, do: :ok
    end
    """)

    for {caller_file, index} <- Enum.with_index(caller_files, 1) do
      File.write!(caller_file, """
      defmodule Sample.Caller#{index} do
        alias Sample.Source

        def call, do: Source.run()
      end
      """)
    end

    {:ok, view, _html} = live(conn, ~p"/")

    open_folder(view, app_root)
    open_file_from_tree(view, app_root, source_file)

    refute has_element?(view, "#related-file-link-list")

    view
    |> element("#toggle-related-files-button")
    |> render_click()

    assert has_element?(view, "#related-file-link-list")
    assert has_element?(view, "#toggle-discovery-related-files-button[aria-pressed=\"false\"]")

    for caller_file <- caller_files do
      assert has_element?(view, related_file_selector(caller_file))
      assert has_element?(view, related_file_reason_selector(caller_file), "used by")
      assert has_element?(view, related_file_context_toggle_selector(caller_file, true))
    end

    toggle_file =
      Enum.find(caller_files, fn caller_file ->
        has_element?(view, related_file_context_toggle_selector(caller_file, true))
      end)

    assert toggle_file

    view
    |> element(related_file_context_toggle_selector(toggle_file, true))
    |> render_click()

    assert has_element?(view, related_file_context_toggle_selector(toggle_file, false))

    view
    |> element("#toggle-discovery-related-files-button")
    |> render_click()

    assert has_element?(view, "#toggle-discovery-related-files-button[aria-pressed=\"true\"]")

    for caller_file <- caller_files do
      assert has_element?(view, related_file_selector(caller_file))
    end

    view
    |> element("#toggle-discovery-related-files-button")
    |> render_click()

    assert has_element?(view, "#toggle-discovery-related-files-button[aria-pressed=\"false\"]")

    view
    |> element("#toggle-related-files-button")
    |> render_click()

    refute has_element?(view, "#related-file-link-list")
  end

  @tag :tmp_dir
  test "empty tab strip searches file contents across umbrella sibling apps", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    web_app = Path.join([tmp_dir, "apps", "web_app"])
    core_app = Path.join([tmp_dir, "apps", "core_app"])
    web_file = Path.join([web_app, "lib", "source.ex"])
    core_file = Path.join([core_app, "lib", "target.ex"])

    File.mkdir_p!(Path.dirname(web_file))
    File.mkdir_p!(Path.dirname(core_file))
    File.write!(Path.join(tmp_dir, "mix.exs"), "defmodule Umbrella.MixProject do\nend\n")
    File.write!(web_file, "defmodule Sample.Source do\nend\n")
    File.write!(core_file, "defmodule Sample.Target do\n  def marker, do: :needle\nend\n")

    {:ok, view, _html} = live(conn, ~p"/")

    open_folder(view, web_app)

    assert has_element?(view, "#file-pattern-search-form")

    view
    |> form("#file-pattern-search-form", file_search: %{pattern: ":needle"})
    |> render_submit()

    assert has_element?(view, related_file_selector(core_file))
  end

  @tag :tmp_dir
  test "folder context menu creates files and folders and deletes empty folders", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    open_folder(view, tmp_dir)

    view
    |> element("#file-explorer")
    |> render_hook("show_folder_context_menu", %{"path" => tmp_dir, "x" => 12, "y" => 16})

    assert has_element?(view, "#folder-context-menu")

    view
    |> form("#context-new-folder-form", folder_action: %{name: "notes"})
    |> render_submit()

    notes_dir = Path.join(tmp_dir, "notes")

    assert File.dir?(notes_dir)

    view
    |> element("#file-explorer")
    |> render_hook("show_folder_context_menu", %{"path" => notes_dir, "x" => 12, "y" => 16})

    view
    |> form("#context-new-file-form", file_action: %{name: "today.md"})
    |> render_submit()

    notes_file = Path.join(notes_dir, "today.md")

    assert File.regular?(notes_file)
    assert has_element?(view, code_editor_selector(notes_file))

    old_dir = Path.join(tmp_dir, "old")
    File.mkdir!(old_dir)

    view
    |> element("#file-explorer")
    |> render_hook("show_folder_context_menu", %{"path" => old_dir, "x" => 12, "y" => 16})

    view
    |> element("#context-delete-folder-button")
    |> render_click()

    refute File.exists?(old_dir)
  end

  @tag :tmp_dir
  test "file context menu renames files, exposes copy path, and deletes files", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    file_path = Path.join(tmp_dir, "draft.md")
    File.write!(file_path, "draft")

    {:ok, view, _html} = live(conn, ~p"/")

    open_folder(view, tmp_dir)
    open_file(view, file_path)

    view
    |> element("#file-explorer")
    |> render_hook("show_file_context_menu", %{"path" => file_path, "x" => 20, "y" => 24})

    assert has_element?(view, "#file-context-menu")

    assert has_element?(
             view,
             ~s(#context-copy-file-path-button[data-clipboard-text="#{file_path}"])
           )

    view
    |> form("#context-rename-file-form", rename_file: %{name: "final.md"})
    |> render_submit()

    renamed_path = Path.join(tmp_dir, "final.md")

    refute File.exists?(file_path)
    assert File.regular?(renamed_path)
    assert has_element?(view, code_editor_selector(renamed_path))

    view
    |> element("#file-explorer")
    |> render_hook("show_file_context_menu", %{"path" => renamed_path, "x" => 20, "y" => 24})

    view
    |> element("#context-delete-file-button")
    |> render_click()

    refute File.exists?(renamed_path)
    refute has_element?(view, tab_selector(renamed_path))
  end

  @tag :tmp_dir
  test "LLM modal shows retained history indicator", %{conn: conn, tmp_dir: tmp_dir} do
    {:ok, view, _html} = live(conn, ~p"/")

    open_folder(view, tmp_dir)

    view
    |> element("#open-llm-button")
    |> render_click()

    assert has_element?(view, "#llm-history-status", "History retained")
  end

  @tag :tmp_dir
  test "sidebar toggles between file explorer and conversation selector", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    conversation_id = Llm.Conversation.new_id(tmp_dir)

    Llm.Conversation.record_turn(
      conversation_id,
      "How does this editor keep chat history?",
      nil,
      project_id: tmp_dir,
      current_file: nil
    )

    {:ok, view, _html} = live(conn, ~p"/")

    open_folder(view, tmp_dir)

    assert has_element?(view, "#file-explorer")
    refute has_element?(view, "#conversation-selector")

    view
    |> element("#show-conversations-sidebar-button")
    |> render_click()

    refute has_element?(view, "#file-explorer")
    assert has_element?(view, "#conversation-selector")
    assert has_element?(view, "#conversation-selector", "How does this editor keep chat history?")

    view
    |> element("#show-files-sidebar-button")
    |> render_click()

    assert has_element?(view, "#file-explorer")
    refute has_element?(view, "#conversation-selector")
  end

  @tag :tmp_dir
  test "selected conversation renders the full transcript in the LLM modal", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    conversation_id = Llm.Conversation.new_id(tmp_dir)

    Llm.Conversation.record_turn(
      conversation_id,
      "Earlier question marker?",
      "Earlier answer marker.",
      project_id: tmp_dir,
      current_file: nil,
      store_assistant?: true
    )

    {:ok, view, _html} = live(conn, ~p"/")

    open_folder(view, tmp_dir)

    view
    |> element("#show-conversations-sidebar-button")
    |> render_click()

    view
    |> element("button[phx-click='select_llm_conversation'][phx-value-id='#{conversation_id}']")
    |> render_click()

    view
    |> element("#open-llm-button")
    |> render_click()

    assert has_element?(view, "#llm-message-list", "Earlier question marker?")
    assert has_element?(view, "#llm-message-list", "Earlier answer marker.")
  end

  #########################################
  # PRIVATE FUNCTIONS
  #########################################
  defp open_folder(view, folder_path) do
    view
    |> form("#folder-search-form", explorer: %{folder_path: folder_path})
    |> render_submit()
  end

  defp open_file(view, file_path) do
    view
    |> element(file_entry_selector(file_path))
    |> render_click()
  end

  defp open_file_from_tree(view, root_path, file_path) do
    root_path = Path.expand(root_path)
    file_path = Path.expand(file_path)

    file_path
    |> Path.relative_to(root_path)
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.reduce(root_path, fn segment, current_path ->
      dir_path = Path.join(current_path, segment)

      view
      |> element(dir_entry_selector(dir_path))
      |> render_click()

      dir_path
    end)

    open_file(view, file_path)
  end

  defp dir_entry_selector(path) do
    ~s(button[phx-click="toggle_dir"][phx-value-path="#{path}"])
  end

  defp file_entry_selector(path) do
    ~s(button[phx-click="open_file"][phx-value-path="#{path}"])
  end

  defp related_file_selector(path) do
    ~s([id="related-file-#{file_tab_dom_id(path)}"])
  end

  defp related_file_open_selector(path) do
    ~s([id="related-file-#{file_tab_dom_id(path)}"] button[phx-click="open_file"])
  end

  defp related_file_functions_selector(path) do
    ~s([id="related-file-functions-#{file_tab_dom_id(path)}"])
  end

  defp related_file_reason_selector(path) do
    ~s([id="related-file-reason-#{file_tab_dom_id(path)}"])
  end

  defp related_file_context_toggle_selector(path, included?) do
    ~s([id="toggle-related-context-#{file_tab_dom_id(path)}"][aria-pressed="#{included?}"])
  end

  defp tab_selector(path) do
    ~s([id="open-tab-#{file_tab_dom_id(path)}"])
  end

  defp select_tab_selector(path) do
    ~s([id="select-tab-#{file_tab_dom_id(path)}"])
  end

  defp close_tab_selector(path) do
    ~s([id="close-tab-#{file_tab_dom_id(path)}"])
  end

  defp code_editor_selector(path) do
    ~s(#code-editor[data-path="#{path}"])
  end

  defp file_tab_dom_id(path) do
    :crypto.hash(:sha256, path)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
  end

  @tag :tmp_dir
  test "conversation selector deletes saved conversations", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    conversation_id = Llm.Conversation.new_id(tmp_dir)

    Llm.Conversation.record_turn(
      conversation_id,
      "Delete me marker?",
      "Delete answer marker.",
      project_id: tmp_dir,
      current_file: nil,
      store_assistant?: true
    )

    {:ok, view, _html} = live(conn, ~p"/")

    open_folder(view, tmp_dir)

    view
    |> element("#show-conversations-sidebar-button")
    |> render_click()

    assert has_element?(view, "#conversation-selector", "Delete me marker?")

    view
    |> element("button[phx-value-id='#{conversation_id}'][phx-click='delete_llm_conversation']")
    |> render_click()

    refute Enum.any?(
             Llm.Conversation.list_for_project(tmp_dir),
             &(&1.id == conversation_id)
           )

    assert Llm.Conversation.get(conversation_id) == nil
    refute render(view) =~ "Delete me marker?"
  end
end
