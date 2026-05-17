defmodule EditorWeb.EditorState do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  @type socket :: term()
  @type load_file_fun :: (socket(), String.t() ->
                            {:ok, socket()} | {:error, String.t(), socket()})
  @type clear_fun :: (socket() -> socket())

  @spec assign_defaults(socket()) :: socket()
  def assign_defaults(socket) do
    socket
    |> assign(:selected_file, nil)
    |> assign(:open_tabs, [])
    |> assign(:related_files, [])
    |> assign(:related_files_collapsed?, true)
    |> assign(:show_discovery_related_files?, false)
    |> assign(:related_file_context_overrides, %{})
    |> assign(:cached_open_files, cached_open_file_metadata())
    |> assign(:file_content, "")
    |> assign(:saved_content, "")
    |> assign(:dirty?, false)
    |> assign(:error_message, nil)
    |> assign(:save_message, nil)
  end

  @spec cached_open_file_metadata() :: [Editor.OpenFileCache.metadata()]
  def cached_open_file_metadata do
    Editor.OpenFileCache.list_files()
    |> Enum.map(&Editor.OpenFileCache.file_metadata/1)
  end

  @spec cache_selected_file(socket(), String.t()) :: :ok
  def cache_selected_file(%{assigns: %{selected_file: path}}, content) when is_binary(path) do
    cache_file(path, content)
  end

  def cache_selected_file(_socket, _content), do: :ok

  @spec cache_file(String.t(), String.t()) :: :ok
  def cache_file(path, content) do
    _cache_result = Editor.OpenFileCache.cache_file(path, content)
    :ok
  end

  @spec open_file(socket(), String.t(), String.t(), [String.t()]) :: socket()
  def open_file(socket, path, content, related_files) do
    socket
    |> assign(:selected_file, path)
    |> assign(:open_tabs, add_open_tab(socket.assigns.open_tabs, path))
    |> assign(:related_files, related_files)
    |> assign(:related_file_context_overrides, %{})
    |> assign(:file_content, content)
    |> assign(:saved_content, content)
    |> assign(:dirty?, false)
    |> assign(:save_message, nil)
    |> assign(:error_message, nil)
    |> assign(:editor_form, to_form(%{"content" => content}, as: :editor))
  end

  @spec apply_edit(socket(), String.t()) :: socket()
  def apply_edit(socket, content) do
    socket
    |> assign(:file_content, content)
    |> assign(:dirty?, content != socket.assigns.saved_content)
    |> assign(:save_message, nil)
    |> assign(:editor_form, to_form(%{"content" => content}, as: :editor))
  end

  @spec apply_save(socket(), String.t(), String.t() | nil, String.t() | nil) :: socket()
  def apply_save(socket, content, save_message, error_message) do
    socket
    |> assign(:file_content, content)
    |> assign(:saved_content, content)
    |> assign(:dirty?, false)
    |> assign(:save_message, save_message)
    |> assign(:error_message, error_message)
    |> assign(:editor_form, to_form(%{"content" => content}, as: :editor))
  end

  @spec clear(socket()) :: socket()
  def clear(socket) do
    socket
    |> assign(:selected_file, nil)
    |> assign(:open_tabs, [])
    |> assign(:related_files, [])
    |> assign(:related_file_context_overrides, %{})
    |> assign(:file_content, "")
    |> assign(:saved_content, "")
    |> assign(:dirty?, false)
    |> assign(:save_message, nil)
    |> assign(:editor_form, to_form(%{"content" => ""}, as: :editor))
  end

  @spec replace_open_tab_path(socket(), String.t(), String.t()) :: socket()
  def replace_open_tab_path(socket, old_path, new_path) do
    open_tabs =
      Enum.map(socket.assigns.open_tabs, fn
        ^old_path -> new_path
        path -> path
      end)

    assign(socket, :open_tabs, open_tabs)
  end

  @spec close_file_tab(socket(), String.t(), load_file_fun(), clear_fun()) :: socket()
  def close_file_tab(socket, path, load_file_fun, clear_fun)
      when is_function(load_file_fun, 2) and is_function(clear_fun, 1) do
    _cache_result = Editor.OpenFileCache.delete_file(path)

    open_tabs = socket.assigns.open_tabs
    remaining_tabs = Enum.reject(open_tabs, &(&1 == path))

    cond do
      socket.assigns.selected_file != path ->
        assign(socket, :open_tabs, remaining_tabs)

      remaining_tabs == [] ->
        clear_fun.(socket)

      true ->
        next_path = next_open_tab(open_tabs, remaining_tabs, path)

        case load_file_fun.(assign(socket, :open_tabs, remaining_tabs), next_path) do
          {:ok, socket} -> socket
          {:error, message, socket} -> assign(socket, :error_message, message)
        end
    end
  end

  defp add_open_tab(open_tabs, path) do
    if path in open_tabs do
      open_tabs
    else
      open_tabs ++ [path]
    end
  end

  defp next_open_tab(open_tabs, remaining_tabs, closed_path) do
    closed_index = Enum.find_index(open_tabs, &(&1 == closed_path)) || 0
    next_index = min(closed_index, length(remaining_tabs) - 1)
    Enum.at(remaining_tabs, next_index)
  end
end
