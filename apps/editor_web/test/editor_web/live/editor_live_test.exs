defmodule EditorWeb.EditorLiveTest do
  use EditorWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @tag :tmp_dir
  test "tracks opened files as switchable tabs", %{conn: conn, tmp_dir: tmp_dir} do
    first_file = Path.join(tmp_dir, "alpha.txt")
    second_file = Path.join(tmp_dir, "beta.txt")

    File.write!(first_file, "alpha")
    File.write!(second_file, "beta")

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#folder-search-form", explorer: %{folder_path: tmp_dir})
    |> render_submit()

    view
    |> element(file_entry_selector(first_file))
    |> render_click()

    assert has_element?(view, tab_selector(first_file))

    view
    |> element(file_entry_selector(second_file))
    |> render_click()

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

    view
    |> form("#folder-search-form", explorer: %{folder_path: web_app})
    |> render_submit()

    view
    |> element(file_entry_selector(source_file))
    |> render_click()

    view
    |> element("#toggle-related-files-button")
    |> render_click()

    assert has_element?(view, related_file_selector(helper_file))
    assert has_element?(view, related_file_reason_selector(helper_file), "uses")
    assert has_element?(view, related_file_functions_selector(helper_file), "call")
    assert has_element?(view, related_file_functions_selector(helper_file), "normalize")

    view
    |> element(related_file_selector(helper_file))
    |> render_click()

    assert has_element?(view, tab_selector(source_file))
    assert has_element?(view, tab_selector(helper_file))
    assert has_element?(view, code_editor_selector(helper_file))
  end

  @tag :tmp_dir
  test "shows all discovered related files for the opened file", %{conn: conn, tmp_dir: tmp_dir} do
    source_file = Path.join([tmp_dir, "lib", "source.ex"])
    caller_files = Enum.map(1..17, &Path.join([tmp_dir, "lib", "caller_#{&1}.ex"]))
    discovery_file = Path.join([tmp_dir, "lib", "discovery.ex"])

    File.mkdir_p!(Path.dirname(source_file))

    File.write!(source_file, """
    defmodule Sample.Source do
      def run, do: :ok
    end
    """)

    for {caller_file, index} <- Enum.with_index(caller_files, 1) do
      File.write!(caller_file, """
      defmodule Sample.Caller#{index} do
        def call, do: Sample.Source.run()
      end
      """)
    end

    File.write!(discovery_file, """
    defmodule Sample.Discovery do
      alias Source

      def noop, do: :ok
    end
    """)

    {:ok, view, _html} = live(conn, ~p"/")

    view
    |> form("#folder-search-form", explorer: %{folder_path: tmp_dir})
    |> render_submit()

    view
    |> element(file_entry_selector(source_file))
    |> render_click()

    for caller_file <- caller_files do
      refute has_element?(view, related_file_selector(caller_file))
    end

    refute has_element?(view, "#related-file-link-list")

    view
    |> element("#toggle-related-files-button")
    |> render_click()

    assert has_element?(view, "#related-file-link-list")
    refute has_element?(view, related_file_selector(discovery_file))

    for caller_file <- caller_files do
      assert has_element?(view, related_file_selector(caller_file))
      assert has_element?(view, related_file_reason_selector(caller_file), "used by")
      assert has_element?(view, related_file_context_toggle_selector(caller_file, true))
    end

    view
    |> element("#toggle-discovery-related-files-button")
    |> render_click()

    assert has_element?(view, "#toggle-discovery-related-files-button[aria-pressed=\"true\"]")
    assert has_element?(view, related_file_selector(discovery_file))
    assert has_element?(view, related_file_reason_selector(discovery_file), "related")

    view
    |> element("#toggle-discovery-related-files-button")
    |> render_click()

    assert has_element?(view, "#toggle-discovery-related-files-button[aria-pressed=\"false\"]")
    refute has_element?(view, related_file_selector(discovery_file))

    first_caller_file = List.first(caller_files)

    view
    |> element(related_file_context_toggle_selector(first_caller_file, true))
    |> render_click()

    assert has_element?(view, related_file_context_toggle_selector(first_caller_file, false))

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

    view
    |> form("#folder-search-form", explorer: %{folder_path: web_app})
    |> render_submit()

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

    view
    |> form("#folder-search-form", explorer: %{folder_path: tmp_dir})
    |> render_submit()

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

    view
    |> form("#folder-search-form", explorer: %{folder_path: tmp_dir})
    |> render_submit()

    view
    |> element(file_entry_selector(file_path))
    |> render_click()

    view
    |> element("#file-explorer")
    |> render_hook("show_file_context_menu", %{"path" => file_path, "x" => 20, "y" => 24})

    assert has_element?(view, "#file-context-menu")
    assert has_element?(view, ~s(#context-copy-file-path-button[data-clipboard-text="#{file_path}"]))

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

  defp file_entry_selector(path) do
    ~s(button[phx-click="open_file"][phx-value-path="#{path}"])
  end

  defp related_file_selector(path), do: ~s([id="related-file-#{file_tab_dom_id(path)}"])

  defp related_file_functions_selector(path),
    do: ~s([id="related-file-functions-#{file_tab_dom_id(path)}"])

  defp related_file_reason_selector(path),
    do: ~s([id="related-file-reason-#{file_tab_dom_id(path)}"])

  defp related_file_context_toggle_selector(path, included?),
    do: ~s([id="toggle-related-context-#{file_tab_dom_id(path)}"][aria-pressed="#{included?}"])

  defp tab_selector(path), do: ~s([id="open-tab-#{file_tab_dom_id(path)}"])

  defp select_tab_selector(path), do: ~s([id="select-tab-#{file_tab_dom_id(path)}"])

  defp close_tab_selector(path), do: ~s([id="close-tab-#{file_tab_dom_id(path)}"])

  defp code_editor_selector(path), do: ~s(#code-editor[data-path="#{path}"])

  defp file_tab_dom_id(path) do
    :crypto.hash(:sha256, path)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
  end
end
