defmodule EditorWeb.EditorLive do
  use EditorWeb, :live_view

  @indent_px 14
  @llm_max_file_chars 12_000

  @impl true
  def mount(_params, _session, socket) do
    default_cwd = File.cwd!()
    connect_params = get_connect_params(socket) || %{}

    stored_folder_path =
      case connect_params do
        %{"stored_folder_path" => path} when is_binary(path) -> path
        _ -> nil
      end

    stored_file_path =
      case connect_params do
        %{"stored_file_path" => path} when is_binary(path) -> path
        _ -> nil
      end

    stored_llm_modal_open =
      case connect_params do
        %{"stored_llm_modal_open" => "true"} -> true
        _ -> false
      end

    stored_llm_question =
      case connect_params do
        %{"stored_llm_question" => question} when is_binary(question) -> question
        _ -> ""
      end

    stored_llm_response =
      case connect_params do
        %{"stored_llm_response" => response} when is_binary(response) -> response
        _ -> nil
      end

    cwd =
      stored_folder_path
      |> normalize_path(default_cwd)
      |> validate_cwd(default_cwd)

    socket =
      socket
      |> assign(:llm_modal_open?, stored_llm_modal_open)
      |> assign(:llm_response, stored_llm_response)
      |> assign(:llm_form, to_form(%{"question" => stored_llm_question}, as: :llm))
      |> base_assigns(cwd)
      |> maybe_restore_selected_file(stored_file_path)

    {:ok, socket}
  end

  @impl true
  def handle_event("open_path", %{"explorer" => %{"folder_path" => folder_path}}, socket) do
    path = normalize_path(folder_path, socket.assigns.cwd)

    socket =
      socket
      |> assign(:form, to_form(%{"folder_path" => path}, as: :explorer))
      |> clear_editor()

    case load_entries_result(path) do
      {:ok, entries} ->
        {:noreply,
         socket
         |> assign(:cwd, path)
         |> assign(:entries, entries)
         |> assign(:error_message, nil)}

      {:error, message} ->
        {:noreply, assign(socket, :error_message, message)}
    end
  end

  @impl true
  def handle_event("toggle_dir", %{"path" => path}, socket) do
    case toggle_directory(socket.assigns.entries, path) do
      {:ok, entries} ->
        {:noreply,
         socket
         |> assign(:entries, entries)
         |> assign(:error_message, nil)}

      {:error, message} ->
        {:noreply, assign(socket, :error_message, message)}
    end
  end

  @impl true
  def handle_event("open_file", %{"path" => path}, socket) do
    case load_file_into_socket(socket, path) do
      {:ok, socket} ->
        {:noreply, socket}

      {:error, message, socket} ->
        {:noreply, assign(socket, :error_message, message)}
    end
  end

  @impl true
  def handle_event("restore_path", %{"folder_path" => folder_path}, socket) do
    path = normalize_path(folder_path, socket.assigns.cwd)

    socket =
      socket
      |> assign(:form, to_form(%{"folder_path" => path}, as: :explorer))
      |> clear_editor()

    case load_entries_result(path) do
      {:ok, entries} ->
        {:noreply,
         socket
         |> assign(:cwd, path)
         |> assign(:entries, entries)
         |> assign(:error_message, nil)}

      {:error, message} ->
        {:noreply, assign(socket, :error_message, message)}
    end
  end

  @impl true
  def handle_event("edit_file", %{"editor" => %{"content" => content}}, socket) do
    {:noreply,
     socket
     |> assign(:file_content, content)
     |> assign(:dirty?, content != socket.assigns.saved_content)
     |> assign(:save_message, nil)
     |> assign(:editor_form, to_form(%{"content" => content}, as: :editor))}
  end

  @impl true
  def handle_event("save_file", %{"editor" => %{"content" => content}}, socket) do
    save_current_file(socket, content)
  end

  @impl true
  def handle_event("save_file", %{}, socket) do
    save_current_file(socket, socket.assigns.file_content)
  end

  @impl true
  def handle_event("open_llm", _params, socket) do
    {:noreply,
     socket
     |> assign(:llm_modal_open?, true)
     |> assign(:llm_loading?, false)
     |> assign(:llm_response, nil)
     |> assign(:llm_error, nil)
     |> assign(:llm_form, to_form(%{"question" => ""}, as: :llm))}
  end

  @impl true
  def handle_event("close_llm", _params, socket) do
    {:noreply,
     socket
     |> assign(:llm_modal_open?, false)
     |> assign(:llm_loading?, false)}
  end

  @impl true
  def handle_event("ask_llm", %{"llm" => %{"question" => question}}, socket) do
    trimmed_question = String.trim(question)

    cond do
      socket.assigns.llm_loading? ->
        {:noreply, socket}

      is_nil(socket.assigns.selected_file) ->
        {:noreply,
         socket
         |> assign(:llm_error, "Open a file before asking the LLM.")
         |> assign(:llm_response, nil)
         |> assign(:llm_form, to_form(%{"question" => question}, as: :llm))}

      trimmed_question == "" ->
        {:noreply,
         socket
         |> assign(:llm_error, "Enter a question.")
         |> assign(:llm_response, nil)
         |> assign(:llm_form, to_form(%{"question" => question}, as: :llm))}

      true ->
        messages =
          Llm.Prompts.editor_file_question(
            socket.assigns.selected_file,
            socket.assigns.file_content,
            trimmed_question
          )

        {:noreply,
         socket
         |> assign(:llm_loading?, true)
         |> assign(:llm_error, nil)
         |> assign(:llm_response, nil)
         |> assign(:llm_form, to_form(%{"question" => question}, as: :llm))
         |> start_async(:ask_llm, fn -> Llm.chat(messages) end)}
    end
  end

  @impl true
  def handle_async(:ask_llm, {:ok, {:ok, response}}, socket) do
    {:noreply,
     socket
     |> assign(:llm_loading?, false)
     |> assign(:llm_response, response)
     |> assign(:llm_error, nil)}
  end

  @impl true
  def handle_async(:ask_llm, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:llm_loading?, false)
     |> assign(:llm_response, nil)
     |> assign(:llm_error, "LLM request failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_async(:ask_llm, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:llm_loading?, false)
     |> assign(:llm_response, nil)
     |> assign(:llm_error, "LLM task crashed: #{inspect(reason)}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <main
        id="editor-shell"
        class="flex h-screen w-full"
        phx-hook="EditorShell"
        data-selected-file-path={@selected_file || ""}
        data-llm-modal-open={to_string(@llm_modal_open?)}
        data-llm-question={Phoenix.HTML.Form.input_value(@llm_form, :question) || ""}
        data-llm-response={@llm_response || ""}
      >
        <aside
          id="editor-sidebar"
          class="flex h-screen w-[15%] shrink-0 flex-col border-r border-base-300 bg-base-200"
        >
          <div class="border-b border-base-300 p-2">
            <.form
              for={@form}
              id="folder-search-form"
              phx-submit="open_path"
              phx-hook="FolderPathStorage"
              data-storage-key="editor:last_folder_path"
              class="w-full"
            >
              <.input
                field={@form[:folder_path]}
                id="folder-path"
                type="text"
                placeholder="/home/ubuntu/project"
                class="w-full rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm outline-none transition focus:border-primary"
              />
            </.form>
          </div>

          <div id="file-explorer" class="flex-1 overflow-y-auto p-2">
            <div class="mb-2 truncate text-xs uppercase tracking-wide text-base-content/50">
              {@cwd}
            </div>

            <%= if @error_message do %>
              <div
                id="explorer-error"
                class="mb-2 rounded-md border border-error/30 bg-error/10 px-2 py-2 text-xs text-error"
              >
                {@error_message}
              </div>
            <% end %>

            <div class="space-y-1">
              <%= for entry <- @entries do %>
                <.tree_node entry={entry} depth={0} selected_file={@selected_file} />
              <% end %>
            </div>
          </div>
        </aside>

        <section id="editor-main" class="flex h-screen flex-1 flex-col bg-base-100">
          <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
            <div class="min-w-0">
              <div class="truncate text-sm font-medium">
                {selected_file_label(@selected_file)}
              </div>
              <%= if @selected_file do %>
                <div class="mt-1 text-xs text-base-content/60">
                  {if @dirty?, do: "Unsaved changes", else: "Saved"}
                </div>
              <% end %>
            </div>

            <%= if @selected_file do %>
              <div class="flex items-center gap-2">
                <button
                  id="open-llm-button"
                  type="button"
                  phx-click="open_llm"
                  class="rounded-md border border-base-300 bg-base-200 px-3 py-2 text-sm font-medium transition hover:bg-base-300"
                >
                  Ask LLM
                </button>

                <.form for={@editor_form} id="editor-save-form" phx-submit="save_file">
                  <button
                    id="save-file-button"
                    type="submit"
                    class="rounded-md border border-base-300 bg-base-200 px-3 py-2 text-sm font-medium transition hover:bg-base-300 disabled:cursor-not-allowed disabled:opacity-50"
                    disabled={!@dirty?}
                  >
                    Save
                  </button>
                </.form>
              </div>
            <% end %>
          </div>

          <%= if @save_message do %>
            <div
              id="save-message"
              class="border-b border-success/20 bg-success/10 px-4 py-2 text-sm text-success"
            >
              {@save_message}
            </div>
          <% end %>

          <div class="flex-1 overflow-hidden">
            <%= if @selected_file do %>
              <div class="h-full">
                <.form for={@editor_form} id="editor-form" phx-submit="save_file" class="hidden">
                  <input type="hidden" name="editor[content]" value={@file_content} />
                </.form>

                <div
                  id="code-editor"
                  phx-hook="CodeEditor"
                  phx-update="ignore"
                  data-content={@file_content}
                  data-path={@selected_file || ""}
                  class="h-full"
                >
                </div>
              </div>
            <% else %>
              <div
                id="editor-empty-state"
                class="flex h-full items-center justify-center px-6 text-sm text-base-content/60"
              >
                Select a file from the explorer.
              </div>
            <% end %>
          </div>
        </section>

        <%= if @llm_modal_open? do %>
          <div
            id="llm-modal-overlay"
            class="fixed inset-0 z-40 bg-black/40"
            phx-click="close_llm"
          >
          </div>

          <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
            <div
              id="llm-modal"
              class="flex h-[70vh] w-full max-w-3xl flex-col overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-2xl"
            >
              <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
                <div class="min-w-0">
                  <div class="text-sm font-semibold">Ask LLM About This File</div>
                  <div class="truncate text-xs text-base-content/60">{@selected_file}</div>
                </div>

                <button
                  id="close-llm-button"
                  type="button"
                  phx-click="close_llm"
                  class="rounded-md border border-base-300 bg-base-200 px-3 py-2 text-sm transition hover:bg-base-300"
                >
                  Close
                </button>
              </div>

              <div class="flex-1 overflow-y-auto px-4 py-4">
                <.form for={@llm_form} id="llm-form" phx-submit="ask_llm" class="space-y-3">
                  <.input
                    field={@llm_form[:question]}
                    id="llm-question"
                    type="text"
                    placeholder="Ask about the current file"
                    class="w-full rounded-md border border-base-300 bg-base-100 px-3 py-2 text-sm outline-none transition focus:border-primary"
                  />

                  <div class="flex justify-end">
                    <button
                      id="submit-llm-button"
                      type="submit"
                      class="rounded-md border border-base-300 bg-base-200 px-3 py-2 text-sm font-medium transition hover:bg-base-300 disabled:cursor-not-allowed disabled:opacity-50"
                      disabled={@llm_loading?}
                    >
                      {if @llm_loading?, do: "Asking...", else: "Ask"}
                    </button>
                  </div>
                </.form>

                <%= if @llm_error do %>
                  <div
                    id="llm-error"
                    class="mt-4 rounded-md border border-error/30 bg-error/10 px-3 py-3 text-sm text-error"
                  >
                    {@llm_error}
                  </div>
                <% end %>

                <%= if @llm_response do %>
                  <div id="llm-response" class="mt-4 space-y-4">
                    <%= for segment <- llm_response_segments(@llm_response) do %>
                      <%= case segment do %>
                        <% {:text, text} -> %>
                          <div class="whitespace-pre-wrap text-sm leading-6 text-base-content">
                            {text}
                          </div>
                        <% {:code, language, code} -> %>
                          <div class="overflow-hidden rounded-xl border border-base-300 bg-base-200/60">
                            <div class="flex items-center justify-between border-b border-base-300 px-4 py-2">
                              <div class="text-xs uppercase tracking-wide text-base-content/60">
                                {if language == "", do: "code", else: language}
                              </div>

                              <button
                                type="button"
                                phx-click={
                                  JS.dispatch("editor:copy", to: "#llm-code-#{code_dom_id(code)}")
                                }
                                class="rounded-md border border-base-300 bg-base-100 px-2 py-1 text-xs transition hover:bg-base-300"
                              >
                                Copy
                              </button>
                            </div>

                            <pre
                              id={"llm-code-#{code_dom_id(code)}"}
                              phx-hook="CopyCodeBlock"
                              data-code={code}
                              class="overflow-x-auto px-4 py-4 text-sm leading-6"
                            ><code>{code}</code></pre>
                          </div>
                      <% end %>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </main>
    </Layouts.app>
    """
  end

  defp llm_response_segments(nil), do: []

  defp llm_response_segments(response) when is_binary(response) do
    parse_llm_response(String.split(response, "\n", trim: false), [], [], nil)
    |> Enum.reverse()
    |> Enum.reject(fn
      {:text, text} -> String.trim(text) == ""
      {:code, _language, code} -> String.trim(code) == ""
    end)
  end

  defp parse_llm_response([], current_lines, segments, nil) do
    text = Enum.reverse(current_lines) |> Enum.join("\n")

    if text == "" do
      segments
    else
      [{:text, text} | segments]
    end
  end

  defp parse_llm_response([], current_lines, segments, language) do
    code = Enum.reverse(current_lines) |> Enum.join("\n")
    [{:code, language, code} | segments]
  end

  defp parse_llm_response([line | rest], current_lines, segments, nil) do
    case Regex.run(~r/^```([\w+-]*)\s*$/, line) do
      [_, language] ->
        text = Enum.reverse(current_lines) |> Enum.join("\n")

        new_segments =
          if text == "" do
            segments
          else
            [{:text, text} | segments]
          end

        parse_llm_response(rest, [], new_segments, language)

      nil ->
        parse_llm_response(rest, [line | current_lines], segments, nil)
    end
  end

  defp parse_llm_response([line | rest], current_lines, segments, language) do
    if String.trim(line) == "```" do
      code = Enum.reverse(current_lines) |> Enum.join("\n")
      parse_llm_response(rest, [], [{:code, language, code} | segments], nil)
    else
      parse_llm_response(rest, [line | current_lines], segments, language)
    end
  end

  defp code_dom_id(code) do
    :crypto.hash(:sha256, code)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
  end

  attr :entry, :map, required: true
  attr :depth, :integer, required: true
  attr :selected_file, :string, default: nil

  defp tree_node(assigns) do
    ~H"""
    <div id={"tree-node-#{@entry.dom_id}"}>
      <%= if @entry.type == :directory do %>
        <button
          id={"dir-toggle-#{@entry.dom_id}"}
          type="button"
          phx-click="toggle_dir"
          phx-value-path={@entry.path}
          class="flex w-full items-center rounded-md px-2 py-1 text-left text-sm transition hover:bg-base-300"
          style={"padding-left: #{padding_left(@depth)}px"}
        >
          <span class="mr-2 inline-block w-4 text-center text-xs">
            {if @entry.expanded?, do: "▾", else: "▸"}
          </span>
          <span class="truncate">{@entry.name}</span>
        </button>

        <%= if @entry.expanded? do %>
          <div class="space-y-1">
            <%= for child <- @entry.children do %>
              <.tree_node entry={child} depth={@depth + 1} selected_file={@selected_file} />
            <% end %>
          </div>
        <% end %>
      <% else %>
        <button
          id={"file-entry-#{@entry.dom_id}"}
          type="button"
          phx-click="open_file"
          phx-value-path={@entry.path}
          class={[
            "flex w-full items-center rounded-md px-2 py-1 text-left text-sm transition hover:bg-base-300",
            @selected_file == @entry.path && "bg-base-300 font-medium"
          ]}
          style={"padding-left: #{padding_left(@depth)}px"}
        >
          <span class="mr-2 inline-block w-4 text-center text-xs">•</span>
          <span class="truncate">{@entry.name}</span>
        </button>
      <% end %>
    </div>
    """
  end

  defp base_assigns(socket, cwd) do
    socket
    |> assign(:current_scope, nil)
    |> assign(:cwd, cwd)
    |> assign(:entries, load_entries(cwd))
    |> assign(:selected_file, nil)
    |> assign(:file_content, "")
    |> assign(:saved_content, "")
    |> assign(:dirty?, false)
    |> assign(:error_message, nil)
    |> assign(:save_message, nil)
    |> assign(:form, to_form(%{"folder_path" => cwd}, as: :explorer))
    |> assign(:editor_form, to_form(%{"content" => ""}, as: :editor))
    |> assign(:llm_modal_open?, false)
    |> assign(:llm_loading?, false)
    |> assign(:llm_response, nil)
    |> assign(:llm_error, nil)
    |> assign(:llm_form, to_form(%{"question" => ""}, as: :llm))
  end

  defp maybe_restore_selected_file(socket, nil), do: socket

  defp maybe_restore_selected_file(socket, path) do
    normalized_path = normalize_path(path, socket.assigns.cwd)

    cond do
      not File.regular?(normalized_path) ->
        socket

      not String.starts_with?(normalized_path, socket.assigns.cwd) ->
        socket

      true ->
        case load_file_into_socket(socket, normalized_path) do
          {:ok, socket} -> socket
          {:error, _message, socket} -> socket
        end
    end
  end

  defp load_file_into_socket(socket, path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok,
         socket
         |> assign(:selected_file, path)
         |> assign(:file_content, content)
         |> assign(:saved_content, content)
         |> assign(:dirty?, false)
         |> assign(:save_message, nil)
         |> assign(:error_message, nil)
         |> assign(:editor_form, to_form(%{"content" => content}, as: :editor))
         |> assign(:llm_response, nil)
         |> assign(:llm_error, nil)}

      {:error, reason} ->
        {:error, "Could not open file: #{:file.format_error(reason)}", socket}
    end
  end

  defp toggle_directory(entries, path) do
    do_toggle_directory(entries, path)
  end

  defp do_toggle_directory(entries, path) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      cond do
        entry.type == :directory and entry.path == path ->
          case toggle_entry(entry) do
            {:ok, updated_entry} ->
              {:cont, {:ok, [updated_entry | acc]}}

            {:error, message} ->
              {:halt, {:error, message}}
          end

        entry.type == :directory ->
          case do_toggle_directory(entry.children, path) do
            {:ok, children} ->
              {:cont, {:ok, [%{entry | children: children} | acc]}}

            {:error, message} ->
              {:halt, {:error, message}}
          end

        true ->
          {:cont, {:ok, [entry | acc]}}
      end
    end)
    |> case do
      {:ok, updated_entries} -> {:ok, Enum.reverse(updated_entries)}
      {:error, message} -> {:error, message}
    end
  end

  defp toggle_entry(entry) do
    if entry.expanded? do
      {:ok, %{entry | expanded?: false}}
    else
      case load_entries_result(entry.path) do
        {:ok, children} ->
          {:ok, %{entry | expanded?: true, children: children}}

        {:error, message} ->
          {:error, message}
      end
    end
  end

  defp clear_editor(socket) do
    socket
    |> assign(:selected_file, nil)
    |> assign(:file_content, "")
    |> assign(:saved_content, "")
    |> assign(:dirty?, false)
    |> assign(:save_message, nil)
    |> assign(:editor_form, to_form(%{"content" => ""}, as: :editor))
    |> assign(:llm_modal_open?, false)
    |> assign(:llm_loading?, false)
    |> assign(:llm_response, nil)
    |> assign(:llm_error, nil)
    |> assign(:llm_form, to_form(%{"question" => ""}, as: :llm))
  end

  defp build_llm_messages(path, content, question) do
    truncated_content =
      if String.length(content) > @llm_max_file_chars do
        String.slice(content, 0, @llm_max_file_chars) <>
          "\n\n[Truncated before sending to the model.]"
      else
        content
      end

    [
      %{
        role: "system",
        content: """
        You are a concise Elixir and Phoenix coding assistant embedded in a text editor.
        Answer only using the provided file contents and the user's question.
        If the file does not contain enough information, say so plainly.
        Prefer short, practical answers.
        """
      },
      %{
        role: "user",
        content: """
        File path: #{path}

        File contents:
        #{truncated_content}

        Question:
        #{question}
        """
      }
    ]
  end

  defp load_entries(path) do
    case load_entries_result(path) do
      {:ok, entries} -> entries
      {:error, _message} -> []
    end
  end

  defp load_entries_result(path) do
    cond do
      path == "" ->
        {:error, "Enter a folder path."}

      not File.dir?(path) ->
        {:error, "Not a directory: #{path}"}

      true ->
        case File.ls(path) do
          {:ok, names} ->
            entries =
              names
              |> Enum.reduce([], fn name, acc ->
                full_path = Path.join(path, name)

                case File.stat(full_path) do
                  {:ok, stat} ->
                    [entry_from_stat(name, full_path, stat.type) | acc]

                  {:error, _reason} ->
                    acc
                end
              end)
              |> Enum.sort_by(fn entry ->
                {entry.type != :directory, String.downcase(entry.name)}
              end)

            {:ok, entries}

          {:error, reason} ->
            {:error, "Could not read directory: #{:file.format_error(reason)}"}
        end
    end
  end

  defp entry_from_stat(name, full_path, type) do
    %{
      name: name,
      path: full_path,
      type: type,
      dom_id: Base.url_encode64(full_path, padding: false),
      expanded?: false,
      children: []
    }
  end

  defp normalize_path(path, current_path) when is_nil(path), do: current_path

  defp normalize_path(path, current_path) do
    trimmed =
      path
      |> String.trim()
      |> String.replace("\\", "/")

    cond do
      trimmed == "" ->
        current_path

      trimmed == "~" or String.starts_with?(trimmed, "~/") ->
        Path.expand(trimmed)

      Path.type(trimmed) == :absolute ->
        Path.expand(trimmed)

      true ->
        Path.expand(trimmed, current_path)
    end
  end

  defp validate_cwd(path, default_cwd) do
    if is_binary(path) and File.dir?(path) do
      path
    else
      default_cwd
    end
  end

  defp padding_left(depth), do: 8 + depth * @indent_px

  defp selected_file_label(nil), do: "No file selected"
  defp selected_file_label(path), do: path

  defp save_current_file(socket, content) do
    case socket.assigns.selected_file do
      nil ->
        {:noreply, assign(socket, :error_message, "No file selected.")}

      path ->
        case File.write(path, content) do
          :ok ->
            case format_file(path) do
              {:ok, formatted_content} ->
                {:noreply,
                 socket
                 |> assign(:file_content, formatted_content)
                 |> assign(:saved_content, formatted_content)
                 |> assign(:dirty?, false)
                 |> assign(:save_message, "Saved and formatted.")
                 |> assign(:error_message, nil)
                 |> assign(:editor_form, to_form(%{"content" => formatted_content}, as: :editor))}

              {:error, message} ->
                {:noreply,
                 socket
                 |> assign(:file_content, content)
                 |> assign(:saved_content, content)
                 |> assign(:dirty?, false)
                 |> assign(:save_message, "Saved.")
                 |> assign(:error_message, message)
                 |> assign(:editor_form, to_form(%{"content" => content}, as: :editor))}
            end

          {:error, reason} ->
            {:noreply,
             assign(socket, :error_message, "Could not save file: #{:file.format_error(reason)}")}
        end
    end
  end

  defp format_file(path) do
    Mix.Task.reenable("format")

    task =
      Task.async(fn ->
        Mix.Task.run("format", [path])
        File.read(path)
      end)

    case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, formatted_content}} ->
        {:ok, formatted_content}

      {:ok, {:error, reason}} ->
        {:error, "Saved, but could not reload formatted file: #{:file.format_error(reason)}"}

      {:exit, reason} ->
        {:error, "Saved, but mix format failed: #{Exception.format_exit(reason)}"}

      nil ->
        {:error, "Saved, but mix format timed out."}
    end
  end
end
