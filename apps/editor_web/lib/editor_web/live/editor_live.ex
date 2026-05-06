defmodule EditorWeb.EditorLive do
  use EditorWeb, :live_view

  @indent_px 14

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

    cwd =
      stored_folder_path
      |> normalize_path(default_cwd)
      |> validate_cwd(default_cwd)

    socket =
      socket
      |> base_assigns(cwd)
      |> maybe_restore_selected_file(stored_file_path)
      |> restore_llm_state(stored_llm_modal_open)

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
         |> reset_llm_conversation(path)
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
  def handle_event("show_folder_context_menu", %{"path" => path, "x" => x, "y" => y}, socket) do
    normalized_path = normalize_path(path, socket.assigns.cwd)

    if context_folder?(socket, normalized_path) do
      {:noreply,
       socket
       |> assign(:file_context_menu, nil)
       |> assign(:folder_context_menu, %{
         path: normalized_path,
         x: normalize_menu_coordinate(x),
         y: normalize_menu_coordinate(y)
       })
       |> assign(:new_folder_form, to_form(%{"name" => ""}, as: :folder_action))
       |> assign(:new_file_form, to_form(%{"name" => ""}, as: :file_action))
       |> assign(:error_message, nil)}
    else
      {:noreply, assign(socket, :folder_context_menu, nil)}
    end
  end

  @impl true
  def handle_event("show_file_context_menu", %{"path" => path, "x" => x, "y" => y}, socket) do
    normalized_path = normalize_path(path, socket.assigns.cwd)

    if context_file?(socket, normalized_path) do
      {:noreply,
       socket
       |> assign(:folder_context_menu, nil)
       |> assign(:file_context_menu, %{
         path: normalized_path,
         x: normalize_menu_coordinate(x),
         y: normalize_menu_coordinate(y)
       })
       |> assign(
         :rename_file_form,
         to_form(%{"name" => Path.basename(normalized_path)}, as: :rename_file)
       )
       |> assign(:error_message, nil)}
    else
      {:noreply, assign(socket, :file_context_menu, nil)}
    end
  end

  @impl true
  def handle_event("hide_context_menus", _params, socket) do
    {:noreply,
     socket
     |> assign(:folder_context_menu, nil)
     |> assign(:file_context_menu, nil)}
  end

  @impl true
  def handle_event("create_folder", %{"folder_action" => %{"name" => name}}, socket) do
    create_child_folder(socket, name)
  end

  @impl true
  def handle_event("create_file", %{"file_action" => %{"name" => name}}, socket) do
    create_child_file(socket, name)
  end

  @impl true
  def handle_event("delete_folder", _params, socket) do
    delete_context_folder(socket)
  end

  @impl true
  def handle_event("rename_file", %{"rename_file" => %{"name" => name}}, socket) do
    rename_context_file(socket, name)
  end

  @impl true
  def handle_event("delete_file", _params, socket) do
    delete_context_file(socket)
  end

  @impl true
  def handle_event("search_files", %{"file_search" => %{"pattern" => pattern}}, socket) do
    search_file_pattern(socket, pattern)
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
  def handle_event("select_tab", %{"path" => path}, socket) do
    if path in socket.assigns.open_tabs do
      case load_file_into_socket(socket, path) do
        {:ok, socket} ->
          {:noreply, socket}

        {:error, message, socket} ->
          {:noreply, assign(socket, :error_message, message)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_tab", %{"path" => path}, socket) do
    {:noreply, close_file_tab(socket, path)}
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
         |> reset_llm_conversation(path)
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
     |> assign(:llm_error, nil)}
  end

  @impl true
  def handle_event("close_llm", _params, socket) do
    {:noreply,
     socket
     |> assign(:llm_modal_open?, false)
     |> assign(:llm_loading?, false)}
  end

  @impl true
  def handle_event("clear_llm_conversation", _params, socket) do
    Llm.Conversation.delete(socket.assigns.llm_conversation_id)

    {:noreply,
     socket
     |> reset_llm_conversation(socket.assigns.cwd)
     |> assign(:llm_loading?, false)
     |> assign(:llm_response, nil)
     |> assign(:llm_context, nil)
     |> assign(:llm_error, nil)
     |> assign(:llm_form, to_form(%{"question" => ""}, as: :llm))}
  end

  @impl true
  def handle_event("toggle_related_files", _params, socket) do
    {:noreply, update(socket, :related_files_collapsed?, &(!&1))}
  end

  @impl true
  def handle_event("toggle_discovery_related_files", _params, socket) do
    {:noreply, update(socket, :show_discovery_related_files?, &(!&1))}
  end

  @impl true
  def handle_event("toggle_related_context", %{"path" => path}, socket) do
    normalized_path = normalize_path(path, socket.assigns.cwd)

    if normalized_path in socket.assigns.related_files do
      included? = related_file_included?(socket, normalized_path)

      {:noreply,
       update(socket, :related_file_context_overrides, fn overrides ->
         Map.put(overrides, normalized_path, not included?)
       end)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("ask_llm", %{"llm" => %{"question" => question}}, socket) do
    trimmed_question = String.trim(question)

    cond do
      socket.assigns.llm_loading? ->
        {:noreply, socket}

      trimmed_question == "" ->
        {:noreply,
         socket
         |> assign(:llm_error, "Enter a question.")
         |> assign(:llm_response, nil)
         |> assign(:llm_context, nil)
         |> assign(:llm_form, to_form(%{"question" => question}, as: :llm))}

      true ->
        context_root =
          related_search_root(
            socket.assigns.cwd,
            socket.assigns.selected_file || socket.assigns.cwd
          )

        conversation_attrs = llm_conversation_attrs(socket)
        Llm.Conversation.ensure(socket.assigns.llm_conversation_id, conversation_attrs)
        recent_messages = Llm.Conversation.recent_messages(socket.assigns.llm_conversation_id)
        conversation_summary = Llm.Conversation.summary(socket.assigns.llm_conversation_id)

        case Llm.build_context(
               context_root,
               socket.assigns.selected_file,
               trimmed_question,
               related_files: llm_related_files(socket),
               related_file_specs: llm_related_file_specs(socket),
               open_files: socket.assigns.open_tabs,
               conversation_id: socket.assigns.llm_conversation_id,
               recent_messages: recent_messages,
               conversation_summary: conversation_summary,
               token_budget: 16_384
             ) do
          {:ok, context} ->
            prompt_stats = Llm.Prompts.stats(context.messages)

            {:noreply,
             socket
             |> assign(:llm_loading?, true)
             |> assign(:llm_error, nil)
             |> assign(:llm_response, nil)
             |> assign(:llm_context, %{
               "mode" => Atom.to_string(context.mode),
               "path" => socket.assigns.selected_file || socket.assigns.cwd,
               "question" => trimmed_question,
               "file_count" => length(context.files),
               "conversation_id" => socket.assigns.llm_conversation_id,
               "recent_message_count" => length(recent_messages),
               "prompt_stats" => prompt_stats
             })
             |> assign(:llm_form, to_form(%{"question" => question}, as: :llm))
             |> assign(:llm_pending_question, trimmed_question)
             |> start_async(:ask_llm, fn -> Llm.chat(context.messages) end)}

          {:error, message} ->
            {:noreply,
             socket
             |> assign(:llm_error, message)
             |> assign(:llm_response, nil)
             |> assign(:llm_context, nil)
             |> assign(:llm_form, to_form(%{"question" => question}, as: :llm))}
        end
    end
  end

  @impl true
  def handle_async(:ask_llm, {:ok, {:ok, response}}, socket) do
    pending_question = socket.assigns.llm_pending_question || ""

    if pending_question != "" do
      Llm.Conversation.record_turn(
        socket.assigns.llm_conversation_id,
        pending_question,
        response,
        llm_conversation_attrs(socket)
      )
    end

    {:noreply,
     socket
     |> assign(:llm_loading?, false)
     |> assign(:llm_response, response)
     |> assign(:llm_pending_question, nil)
     |> assign(:llm_error, nil)}
  end

  @impl true
  def handle_async(:ask_llm, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:llm_loading?, false)
     |> assign(:llm_response, nil)
     |> assign(:llm_context, nil)
     |> assign(:llm_pending_question, nil)
     |> assign(:llm_error, "LLM request failed: #{inspect(reason)}")}
  end

  @impl true
  def handle_async(:ask_llm, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:llm_loading?, false)
     |> assign(:llm_response, nil)
     |> assign(:llm_context, nil)
     |> assign(:llm_pending_question, nil)
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

          <div
            id="file-explorer"
            class="flex-1 overflow-y-auto p-2"
            phx-hook="FileExplorerContextMenu"
          >
            <div
              class="mb-2 truncate rounded-md px-2 py-1 text-xs uppercase tracking-wide text-base-content/50"
              data-context-folder-path={@cwd}
            >
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

        <%= if @folder_context_menu do %>
          <div
            id="folder-context-menu"
            class="fixed z-50 w-72 overflow-hidden rounded-md border border-base-300 bg-base-100 text-sm shadow-xl"
            style={"left: #{@folder_context_menu.x}px; top: #{@folder_context_menu.y}px;"}
          >
            <div class="border-b border-base-300 bg-base-200 px-3 py-2">
              <div class="truncate text-xs font-semibold uppercase tracking-wide text-base-content/60">
                Folder
              </div>
              <div class="mt-1 truncate font-medium" title={@folder_context_menu.path}>
                {Path.basename(@folder_context_menu.path)}
              </div>
            </div>

            <div class="space-y-3 p-3">
              <.form
                for={@new_folder_form}
                id="context-new-folder-form"
                phx-submit="create_folder"
                class="space-y-2"
              >
                <.input
                  field={@new_folder_form[:name]}
                  id="context-new-folder-name"
                  type="text"
                  placeholder="New folder"
                  class="w-full rounded-md border border-base-300 bg-base-100 px-2 py-1.5 text-xs outline-none transition focus:border-primary"
                />
                <button
                  id="context-create-folder-button"
                  type="submit"
                  class="w-full rounded-md border border-base-300 bg-base-200 px-2 py-1.5 text-xs font-medium transition hover:bg-base-300"
                >
                  Create Folder
                </button>
              </.form>

              <.form
                for={@new_file_form}
                id="context-new-file-form"
                phx-submit="create_file"
                class="space-y-2"
              >
                <.input
                  field={@new_file_form[:name]}
                  id="context-new-file-name"
                  type="text"
                  placeholder="New file"
                  class="w-full rounded-md border border-base-300 bg-base-100 px-2 py-1.5 text-xs outline-none transition focus:border-primary"
                />
                <button
                  id="context-create-file-button"
                  type="submit"
                  class="w-full rounded-md border border-base-300 bg-base-200 px-2 py-1.5 text-xs font-medium transition hover:bg-base-300"
                >
                  Create File
                </button>
              </.form>
            </div>

            <div class="border-t border-base-300 p-3">
              <button
                id="context-delete-folder-button"
                type="button"
                phx-click="delete_folder"
                class="w-full rounded-md border border-error/40 bg-error/10 px-2 py-1.5 text-xs font-medium text-error transition hover:bg-error/20"
              >
                Delete Empty Folder
              </button>
            </div>
          </div>
        <% end %>

        <%= if @file_context_menu do %>
          <div
            id="file-context-menu"
            class="fixed z-50 w-72 overflow-hidden rounded-md border border-base-300 bg-base-100 text-sm shadow-xl"
            style={"left: #{@file_context_menu.x}px; top: #{@file_context_menu.y}px;"}
          >
            <div class="border-b border-base-300 bg-base-200 px-3 py-2">
              <div class="truncate text-xs font-semibold uppercase tracking-wide text-base-content/60">
                File
              </div>
              <div class="mt-1 truncate font-medium" title={@file_context_menu.path}>
                {Path.basename(@file_context_menu.path)}
              </div>
            </div>

            <div class="space-y-3 p-3">
              <.form
                for={@rename_file_form}
                id="context-rename-file-form"
                phx-submit="rename_file"
                class="space-y-2"
              >
                <.input
                  field={@rename_file_form[:name]}
                  id="context-rename-file-name"
                  type="text"
                  placeholder="Filename"
                  class="w-full rounded-md border border-base-300 bg-base-100 px-2 py-1.5 text-xs outline-none transition focus:border-primary"
                />
                <button
                  id="context-rename-file-button"
                  type="submit"
                  class="w-full rounded-md border border-base-300 bg-base-200 px-2 py-1.5 text-xs font-medium transition hover:bg-base-300"
                >
                  Rename File
                </button>
              </.form>

              <button
                id="context-copy-file-path-button"
                type="button"
                data-clipboard-text={@file_context_menu.path}
                class="w-full rounded-md border border-base-300 bg-base-200 px-2 py-1.5 text-xs font-medium transition hover:bg-base-300"
              >
                Copy Path
              </button>
            </div>

            <div class="border-t border-base-300 p-3">
              <button
                id="context-delete-file-button"
                type="button"
                phx-click="delete_file"
                class="w-full rounded-md border border-error/40 bg-error/10 px-2 py-1.5 text-xs font-medium text-error transition hover:bg-error/20"
              >
                Delete File
              </button>
            </div>
          </div>
        <% end %>

        <section id="editor-main" class="flex h-screen min-w-0 flex-1 flex-col bg-base-100">
          <header class="border-b border-base-300">
            <div class="flex items-center justify-between px-4 py-3">
              <div class="min-w-0">
                <div class="truncate text-sm font-medium">
                  {selected_file_label(@selected_file)}
                </div>
                <div class="mt-1 text-xs text-base-content/60">
                  <%= if @selected_file do %>
                    {if @dirty?, do: "Unsaved changes", else: "Saved"}
                  <% else %>
                    Ask the LLM about the current folder or open a file for file-specific context.
                  <% end %>
                </div>
              </div>

              <div class="flex items-center gap-2">
                <button
                  id="open-llm-button"
                  type="button"
                  phx-click="open_llm"
                  class="rounded-md border border-base-300 bg-base-200 px-3 py-2 text-sm font-medium transition hover:bg-base-300"
                >
                  Ask LLM
                </button>

                <%= if @selected_file do %>
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
                <% end %>
              </div>
            </div>

            <nav
              id="open-file-tabs"
              class="flex h-10 min-w-0 overflow-hidden border-t border-base-300 bg-base-200/60"
              aria-label="Open files"
            >
              <div
                :if={@open_tabs == []}
                id="open-file-tabs-empty"
                class="flex min-w-0 flex-1 items-center gap-3 px-4"
              >
                <span class="shrink-0 text-xs text-base-content/50">No open files</span>
                <.form
                  for={@file_search_form}
                  id="file-pattern-search-form"
                  phx-submit="search_files"
                  class="flex min-w-0 flex-1 items-center gap-2"
                >
                  <.input
                    field={@file_search_form[:pattern]}
                    id="file-pattern-search"
                    type="text"
                    placeholder="Search pattern in files"
                    class="h-7 min-w-0 flex-1 rounded-md border border-base-300 bg-base-100 px-2 py-1 text-xs outline-none transition focus:border-primary"
                  />
                  <button
                    id="file-pattern-search-button"
                    type="submit"
                    class="h-7 shrink-0 rounded-md border border-base-300 bg-base-100 px-2 text-xs font-medium transition hover:bg-base-300"
                  >
                    Search
                  </button>
                </.form>
              </div>

              <div
                :for={path <- @open_tabs}
                id={"open-tab-#{file_tab_dom_id(path)}"}
                class={[
                  "flex min-w-0 flex-1 basis-0 items-center border-r border-base-300",
                  @selected_file == path && "bg-base-100"
                ]}
              >
                <button
                  id={"select-tab-#{file_tab_dom_id(path)}"}
                  type="button"
                  phx-click="select_tab"
                  phx-value-path={path}
                  title={path}
                  class={[
                    "min-w-0 flex-1 truncate px-3 py-2 text-left text-xs transition hover:bg-base-300/70",
                    @selected_file == path && "font-medium"
                  ]}
                >
                  {open_tab_label(path)}
                  <span :if={@selected_file == path and @dirty?} class="text-warning">*</span>
                </button>

                <button
                  id={"close-tab-#{file_tab_dom_id(path)}"}
                  type="button"
                  phx-click="close_tab"
                  phx-value-path={path}
                  aria-label={"Close #{open_tab_label(path)}"}
                  class="flex h-full w-8 shrink-0 items-center justify-center text-base-content/50 transition hover:bg-base-300 hover:text-base-content"
                >
                  <.icon name="hero-x-mark" class="h-4 w-4" />
                </button>
              </div>
            </nav>

            <div
              :if={@related_files != []}
              id="related-file-links"
              class="flex min-w-0 items-center gap-2 border-t border-base-300 bg-base-100 px-4 py-2"
            >
              <button
                id="toggle-related-files-button"
                type="button"
                phx-click="toggle_related_files"
                aria-expanded={to_string(not @related_files_collapsed?)}
                class="flex shrink-0 items-center gap-1 rounded-md px-1.5 py-1 text-xs font-medium uppercase tracking-wide text-base-content/60 transition hover:bg-base-200 hover:text-base-content"
              >
                <.icon
                  name={
                    if(@related_files_collapsed?,
                      do: "hero-chevron-right",
                      else: "hero-chevron-down"
                    )
                  }
                  class="h-3.5 w-3.5"
                />
                <span>Related</span>
                <span class="rounded bg-base-300 px-1.5 py-0.5 text-[0.65rem] leading-none">
                  {length(@related_files)}
                </span>
              </button>

              <button
                :if={!@related_files_collapsed?}
                id="toggle-discovery-related-files-button"
                type="button"
                phx-click="toggle_discovery_related_files"
                aria-pressed={to_string(@show_discovery_related_files?)}
                class={[
                  "flex shrink-0 items-center gap-1 rounded-md px-1.5 py-1 text-xs font-medium transition hover:bg-base-200 hover:text-base-content",
                  @show_discovery_related_files? && "text-base-content/80",
                  !@show_discovery_related_files? && "text-base-content/45"
                ]}
              >
                <.icon
                  name={if(@show_discovery_related_files?, do: "hero-eye", else: "hero-eye-slash")}
                  class="h-3.5 w-3.5"
                />
                <span>Related</span>
              </button>

              <div
                :if={!@related_files_collapsed?}
                id="related-file-link-list"
                class="flex min-w-0 flex-1 flex-wrap items-center gap-2"
              >
                <div
                  :for={
                    path <-
                      displayed_related_files(
                        @selected_file,
                        @related_files,
                        @show_discovery_related_files?
                      )
                  }
                  id={"related-file-#{file_tab_dom_id(path)}"}
                  class="group relative shrink-0"
                >
                  <div class="flex max-w-80 items-center rounded-md border border-base-300 bg-base-200 text-xs transition hover:bg-base-300">
                    <button
                      type="button"
                      phx-click="open_file"
                      phx-value-path={path}
                      class="flex min-w-0 items-center gap-1 px-2 py-1 text-left"
                    >
                      <span class="truncate">{related_file_label(@cwd, path)}</span>
                      <span
                        id={"related-file-reason-#{file_tab_dom_id(path)}"}
                        class="shrink-0 rounded bg-base-300 px-1 py-0.5 text-[0.65rem] leading-none text-base-content/60"
                      >
                        {related_file_reason(@selected_file, path)}
                      </span>
                    </button>

                    <button
                      id={"toggle-related-context-#{file_tab_dom_id(path)}"}
                      type="button"
                      phx-click="toggle_related_context"
                      phx-value-path={path}
                      aria-pressed={
                        to_string(
                          related_file_included?(
                            @selected_file,
                            path,
                            @related_file_context_overrides
                          )
                        )
                      }
                      class={[
                        "border-l border-base-300 px-1.5 py-1 font-medium transition",
                        related_file_included?(
                          @selected_file,
                          path,
                          @related_file_context_overrides
                        ) && "text-success",
                        !related_file_included?(
                          @selected_file,
                          path,
                          @related_file_context_overrides
                        ) && "text-base-content/40"
                      ]}
                    >
                      <.icon
                        name={
                          if(
                            related_file_included?(
                              @selected_file,
                              path,
                              @related_file_context_overrides
                            ),
                            do: "hero-check",
                            else: "hero-minus"
                          )
                        }
                        class="h-3.5 w-3.5"
                      />
                    </button>
                  </div>

                  <div class="pointer-events-none absolute left-0 top-full z-40 mt-2 hidden w-72 rounded-md border border-base-300 bg-neutral px-3 py-2 text-xs text-neutral-content shadow-xl group-hover:block">
                    <div class="truncate font-medium">{Path.relative_to(path, @cwd)}</div>
                    <div class="mt-1 text-neutral-content/70">
                      Relationship: {related_file_reason(@selected_file, path)}
                    </div>
                    <div class="mt-1 text-neutral-content/70">
                      LLM context: {if related_file_included?(
                                         @selected_file,
                                         path,
                                         @related_file_context_overrides
                                       ),
                                       do: "included",
                                       else: "excluded"}
                    </div>
                    <div
                      :if={!strong_related_file?(@selected_file, path)}
                      class="mt-1 text-neutral-content/60"
                    >
                      Shown for discovery only; not included in default LLM context.
                    </div>
                    <div class="mt-2 text-neutral-content/70">Functions</div>
                    <div
                      id={"related-file-functions-#{file_tab_dom_id(path)}"}
                      class="mt-1 flex flex-wrap gap-1"
                    >
                      <%= for function <- related_file_functions(path) do %>
                        <span
                          class="max-w-full truncate rounded bg-neutral-content/10 px-1.5 py-0.5 font-mono"
                          title={"#{function.head} (lines #{function.start_line}-#{function.end_line})"}
                        >
                          {function.name}
                        </span>
                      <% end %>
                      <span
                        :if={related_file_functions(path) == []}
                        class="text-neutral-content/60"
                      >
                        None found
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </header>

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
                Select a file from the explorer, or ask the LLM about the current folder.
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
              class="llm-crt flex h-[70vh] w-full max-w-3xl flex-col overflow-hidden rounded-lg"
            >
              <div class="llm-crt-header flex items-center justify-between px-4 py-3">
                <div class="min-w-0">
                  <div class="llm-crt-title text-sm font-semibold uppercase">Ask LLM</div>
                  <div class="llm-crt-muted truncate text-xs">
                    {llm_target_label(@cwd, @selected_file)}
                  </div>
                </div>

                <div class="flex items-center gap-2">
                  <button
                    id="clear-llm-conversation-button"
                    type="button"
                    phx-click="clear_llm_conversation"
                    class="llm-crt-button rounded px-3 py-2 text-sm transition"
                  >
                    Clear
                  </button>

                  <button
                    id="close-llm-button"
                    type="button"
                    phx-click="close_llm"
                    class="llm-crt-button rounded px-3 py-2 text-sm transition"
                  >
                    Close
                  </button>
                </div>
              </div>

              <div class="llm-crt-body flex-1 overflow-y-auto px-4 py-4">
                <.form for={@llm_form} id="llm-form" phx-submit="ask_llm" class="space-y-3">
                  <.input
                    field={@llm_form[:question]}
                    id="llm-question"
                    type="text"
                    placeholder="Ask about the current file or folder"
                    class="llm-crt-input w-full rounded px-3 py-2 text-sm outline-none transition"
                  />

                  <div class="flex justify-end">
                    <button
                      id="submit-llm-button"
                      type="submit"
                      class="llm-crt-button rounded px-3 py-2 text-sm font-medium transition disabled:cursor-not-allowed disabled:opacity-50"
                      disabled={@llm_loading?}
                    >
                      {if @llm_loading?, do: "Asking...", else: "Ask"}
                    </button>
                  </div>
                </.form>

                <div
                  :if={llm_prompt_stats_label(@llm_context)}
                  id="llm-prompt-stats"
                  class="llm-crt-muted mt-3 text-xs"
                >
                  {llm_prompt_stats_label(@llm_context)}
                </div>

                <%= if @llm_error do %>
                  <div
                    id="llm-error"
                    class="llm-crt-error mt-4 rounded px-3 py-3 text-sm"
                  >
                    {@llm_error}
                  </div>
                <% end %>

                <%= if @llm_response do %>
                  <div id="llm-response" class="mt-4 space-y-4">
                    <%= for segment <- llm_response_segments(@llm_response) do %>
                      <%= case segment do %>
                        <% {:text, text} -> %>
                          <.markdown_text text={text} />
                        <% {:code, language, code} -> %>
                          <div class="llm-crt-code overflow-hidden rounded">
                            <div class="llm-crt-code-header flex items-center justify-between px-4 py-2">
                              <div class="llm-crt-muted text-xs uppercase">
                                {if language == "", do: "code", else: language}
                              </div>

                              <button
                                type="button"
                                phx-click={
                                  JS.dispatch("editor:copy", to: "#llm-code-#{code_dom_id(code)}")
                                }
                                class="llm-crt-button rounded px-2 py-1 text-xs transition"
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

  attr(:text, :string, required: true)

  defp markdown_text(assigns) do
    ~H"""
    <div class="space-y-3 text-sm leading-6 text-base-content">
      <%= for block <- markdown_blocks(@text) do %>
        <%= case block do %>
          <% {:heading, level, inlines} -> %>
            <div class={heading_class(level)}>
              <.markdown_inlines items={inlines} />
            </div>
          <% {:paragraph, inlines} -> %>
            <p>
              <.markdown_inlines items={inlines} />
            </p>
          <% {:ordered_list, items} -> %>
            <ol class="list-decimal space-y-1 pl-5">
              <li :for={item <- items}>
                <.markdown_inlines items={item} />
              </li>
            </ol>
          <% {:unordered_list, items} -> %>
            <ul class="list-disc space-y-1 pl-5">
              <li :for={item <- items}>
                <.markdown_inlines items={item} />
              </li>
            </ul>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr(:items, :list, required: true)

  defp markdown_inlines(assigns) do
    ~H"""
    <%= for item <- @items do %>
      <%= case item do %>
        <% {:text, text} -> %>
          {text}
        <% {:code, code} -> %>
          <code class="rounded bg-base-200 px-1 py-0.5 font-mono text-[0.9em]">{code}</code>
        <% {:strong, children} -> %>
          <strong class="font-semibold">
            <.markdown_inlines items={children} />
          </strong>
      <% end %>
    <% end %>
    """
  end

  defp markdown_blocks(text) do
    text
    |> String.split("\n", trim: false)
    |> parse_markdown_blocks([], nil)
    |> Enum.reverse()
  end

  defp parse_markdown_blocks([], blocks, nil), do: blocks

  defp parse_markdown_blocks([], blocks, current_block) do
    push_markdown_block(blocks, current_block)
  end

  defp parse_markdown_blocks([line | rest], blocks, current_block) do
    trimmed_line = String.trim(line)

    cond do
      trimmed_line == "" ->
        parse_markdown_blocks(rest, push_markdown_block(blocks, current_block), nil)

      heading = Regex.run(~r/^(\#{1,3})\s+(.+)$/, trimmed_line) ->
        [_, marks, content] = heading

        blocks =
          blocks
          |> push_markdown_block(current_block)
          |> push_markdown_block({:heading, String.length(marks), content})

        parse_markdown_blocks(rest, blocks, nil)

      ordered_item = Regex.run(~r/^\d+\.\s+(.+)$/, trimmed_line) ->
        [_, content] = ordered_item

        case current_block do
          {:ordered_list, items} ->
            parse_markdown_blocks(rest, blocks, {:ordered_list, items ++ [content]})

          _ ->
            parse_markdown_blocks(
              rest,
              push_markdown_block(blocks, current_block),
              {:ordered_list, [content]}
            )
        end

      unordered_item = Regex.run(~r/^[-*]\s+(.+)$/, trimmed_line) ->
        [_, content] = unordered_item

        case current_block do
          {:unordered_list, items} ->
            parse_markdown_blocks(rest, blocks, {:unordered_list, items ++ [content]})

          _ ->
            parse_markdown_blocks(
              rest,
              push_markdown_block(blocks, current_block),
              {:unordered_list, [content]}
            )
        end

      true ->
        case current_block do
          {:paragraph, lines} ->
            parse_markdown_blocks(rest, blocks, {:paragraph, lines ++ [trimmed_line]})

          _ ->
            parse_markdown_blocks(
              rest,
              push_markdown_block(blocks, current_block),
              {:paragraph, [trimmed_line]}
            )
        end
    end
  end

  defp push_markdown_block(blocks, nil), do: blocks

  defp push_markdown_block(blocks, {:paragraph, lines}) do
    [{:paragraph, inline_tokens(Enum.join(lines, " "))} | blocks]
  end

  defp push_markdown_block(blocks, {:heading, level, content}) do
    [{:heading, level, inline_tokens(content)} | blocks]
  end

  defp push_markdown_block(blocks, {:ordered_list, items}) do
    [{:ordered_list, Enum.map(items, &inline_tokens/1)} | blocks]
  end

  defp push_markdown_block(blocks, {:unordered_list, items}) do
    [{:unordered_list, Enum.map(items, &inline_tokens/1)} | blocks]
  end

  defp inline_tokens(text) do
    Regex.split(~r/(\*\*.+?\*\*|`[^`]+`)/, text, include_captures: true, trim: false)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&markdown_inline/1)
  end

  defp markdown_inline("**" <> rest = value) do
    if String.ends_with?(value, "**") do
      content = String.slice(rest, 0, String.length(rest) - 2)
      {:strong, code_inlines(content)}
    else
      {:text, value}
    end
  end

  defp markdown_inline("`" <> rest = value) do
    if String.ends_with?(value, "`") do
      {:code, String.slice(rest, 0, String.length(rest) - 1)}
    else
      {:text, value}
    end
  end

  defp markdown_inline(text), do: {:text, text}

  defp code_inlines(text) do
    Regex.split(~r/(`[^`]+`)/, text, include_captures: true, trim: false)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&markdown_inline/1)
  end

  defp heading_class(1), do: "text-lg font-semibold"
  defp heading_class(2), do: "text-base font-semibold"
  defp heading_class(_level), do: "text-sm font-semibold"

  attr(:entry, :map, required: true)
  attr(:depth, :integer, required: true)
  attr(:selected_file, :string, default: nil)

  defp tree_node(assigns) do
    ~H"""
    <div id={"tree-node-#{@entry.dom_id}"}>
      <%= if @entry.type == :directory do %>
        <button
          id={"dir-toggle-#{@entry.dom_id}"}
          type="button"
          phx-click="toggle_dir"
          phx-value-path={@entry.path}
          data-context-folder-path={@entry.path}
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
          data-context-file-path={@entry.path}
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
    |> assign(:open_tabs, [])
    |> assign(:related_files, [])
    |> assign(:related_files_collapsed?, true)
    |> assign(:show_discovery_related_files?, false)
    |> assign(:related_file_context_overrides, %{})
    |> assign(:file_content, "")
    |> assign(:saved_content, "")
    |> assign(:dirty?, false)
    |> assign(:error_message, nil)
    |> assign(:save_message, nil)
    |> assign(:folder_context_menu, nil)
    |> assign(:file_context_menu, nil)
    |> assign(:new_folder_form, to_form(%{"name" => ""}, as: :folder_action))
    |> assign(:new_file_form, to_form(%{"name" => ""}, as: :file_action))
    |> assign(:rename_file_form, to_form(%{"name" => ""}, as: :rename_file))
    |> assign(:file_search_form, to_form(%{"pattern" => ""}, as: :file_search))
    |> assign(:form, to_form(%{"folder_path" => cwd}, as: :explorer))
    |> assign(:editor_form, to_form(%{"content" => ""}, as: :editor))
    |> assign(:llm_modal_open?, false)
    |> assign(:llm_loading?, false)
    |> assign(:llm_response, nil)
    |> assign(:llm_context, nil)
    |> assign(:llm_error, nil)
    |> assign(:llm_conversation_id, new_llm_conversation_id(cwd))
    |> assign(:llm_pending_question, nil)
    |> assign(:llm_form, to_form(%{"question" => ""}, as: :llm))
  end

  defp reset_llm_conversation(socket, cwd) do
    socket
    |> assign(:llm_conversation_id, new_llm_conversation_id(cwd))
    |> assign(:llm_pending_question, nil)
  end

  defp new_llm_conversation_id(cwd) do
    conversation_id = Llm.Conversation.new_id(cwd)
    Llm.Conversation.ensure(conversation_id, project_id: cwd)
    conversation_id
  end

  defp llm_conversation_attrs(socket) do
    %{
      project_id: socket.assigns.cwd,
      current_file: socket.assigns.selected_file
    }
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
         |> assign(:open_tabs, add_open_tab(socket.assigns.open_tabs, path))
         |> assign(:related_files, related_file_paths(socket.assigns.cwd, path, content))
         |> assign(:related_file_context_overrides, %{})
         |> assign(:file_content, content)
         |> assign(:saved_content, content)
         |> assign(:dirty?, false)
         |> assign(:save_message, nil)
         |> assign(:error_message, nil)
         |> assign(:editor_form, to_form(%{"content" => content}, as: :editor))}

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
    |> assign(:open_tabs, [])
    |> assign(:related_files, [])
    |> assign(:file_content, "")
    |> assign(:saved_content, "")
    |> assign(:dirty?, false)
    |> assign(:save_message, nil)
    |> assign(:editor_form, to_form(%{"content" => ""}, as: :editor))
    |> assign(:llm_modal_open?, false)
    |> assign(:llm_loading?, false)
    |> assign(:llm_response, nil)
    |> assign(:llm_context, nil)
    |> assign(:llm_error, nil)
    |> assign(:llm_pending_question, nil)
    |> assign(:llm_form, to_form(%{"question" => ""}, as: :llm))
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

  defp restore_llm_state(socket, modal_open?) do
    assign(socket, :llm_modal_open?, modal_open?)
  end

  defp search_file_pattern(socket, pattern) do
    trimmed_pattern = String.trim(pattern || "")

    cond do
      trimmed_pattern == "" ->
        {:noreply,
         socket
         |> assign(:related_files, [])
         |> assign(:file_search_form, to_form(%{"pattern" => pattern}, as: :file_search))
         |> assign(:error_message, "Enter a search pattern.")}

      true ->
        search_root = related_search_root(socket.assigns.cwd, socket.assigns.cwd)
        matches = matching_file_paths(search_root, trimmed_pattern)

        {:noreply,
         socket
         |> assign(:related_files, matches)
         |> assign(:file_search_form, to_form(%{"pattern" => pattern}, as: :file_search))
         |> assign(:error_message, nil)}
    end
  end

  defp create_child_folder(socket, name) do
    with {:ok, parent_path} <- context_menu_folder(socket),
         {:ok, child_path} <- child_path(parent_path, name),
         :ok <- File.mkdir(child_path) do
      {:noreply,
       socket
       |> refresh_explorer()
       |> assign(:folder_context_menu, nil)
       |> assign(:error_message, nil)}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, :error_message, message)}

      {:error, reason} ->
        {:noreply,
         assign(socket, :error_message, "Could not create folder: #{format_reason(reason)}")}
    end
  end

  defp create_child_file(socket, name) do
    with {:ok, parent_path} <- context_menu_folder(socket),
         {:ok, child_path} <- child_path(parent_path, name),
         {:ok, :ok} <- File.open(child_path, [:write, :exclusive], fn _file -> :ok end) do
      socket =
        socket
        |> refresh_explorer()
        |> assign(:folder_context_menu, nil)
        |> assign(:error_message, nil)

      case load_file_into_socket(socket, child_path) do
        {:ok, socket} ->
          {:noreply, socket}

        {:error, message, socket} ->
          {:noreply, assign(socket, :error_message, message)}
      end
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, :error_message, message)}

      {:error, reason} ->
        {:noreply,
         assign(socket, :error_message, "Could not create file: #{format_reason(reason)}")}
    end
  end

  defp delete_context_folder(socket) do
    with {:ok, path} <- context_menu_folder(socket),
         :ok <- ensure_not_root_folder(socket, path),
         :ok <- File.rmdir(path) do
      {:noreply,
       socket
       |> refresh_explorer()
       |> assign(:folder_context_menu, nil)
       |> assign(:error_message, nil)}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, :error_message, message)}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :error_message,
           "Could not delete folder: #{format_delete_reason(reason)}"
         )}
    end
  end

  defp rename_context_file(socket, name) do
    with {:ok, old_path} <- context_menu_file(socket),
         :ok <- ensure_file_can_change(socket, old_path, "rename"),
         {:ok, new_path} <- sibling_path(old_path, name),
         :ok <- File.rename(old_path, new_path) do
      socket =
        socket
        |> replace_open_tab_path(old_path, new_path)
        |> refresh_explorer()
        |> assign(:file_context_menu, nil)
        |> assign(:error_message, nil)

      if socket.assigns.selected_file == old_path do
        case load_file_into_socket(socket, new_path) do
          {:ok, socket} -> {:noreply, socket}
          {:error, message, socket} -> {:noreply, assign(socket, :error_message, message)}
        end
      else
        {:noreply, socket}
      end
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, :error_message, message)}

      {:error, reason} ->
        {:noreply,
         assign(socket, :error_message, "Could not rename file: #{format_reason(reason)}")}
    end
  end

  defp delete_context_file(socket) do
    with {:ok, path} <- context_menu_file(socket),
         :ok <- ensure_file_can_change(socket, path, "delete"),
         :ok <- File.rm(path) do
      {:noreply,
       socket
       |> close_deleted_file(path)
       |> refresh_explorer()
       |> assign(:file_context_menu, nil)
       |> assign(:error_message, nil)}
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, :error_message, message)}

      {:error, reason} ->
        {:noreply,
         assign(socket, :error_message, "Could not delete file: #{format_reason(reason)}")}
    end
  end

  defp context_menu_folder(%{assigns: %{folder_context_menu: %{path: path}}} = socket) do
    if context_folder?(socket, path) do
      {:ok, path}
    else
      {:error, "Right-click a folder inside the current workspace."}
    end
  end

  defp context_menu_folder(_socket), do: {:error, "Right-click a folder first."}

  defp context_menu_file(%{assigns: %{file_context_menu: %{path: path}}} = socket) do
    if context_file?(socket, path) do
      {:ok, path}
    else
      {:error, "Right-click a file inside the current workspace."}
    end
  end

  defp context_menu_file(_socket), do: {:error, "Right-click a file first."}

  defp context_folder?(socket, path) do
    File.dir?(path) and path_within_root?(path, socket.assigns.cwd)
  end

  defp context_file?(socket, path) do
    File.regular?(path) and path_within_root?(path, socket.assigns.cwd)
  end

  defp child_path(parent_path, name) do
    trimmed_name = String.trim(name || "")

    if valid_child_name?(trimmed_name) do
      {:ok, Path.expand(trimmed_name, parent_path)}
    else
      {:error, "Use a file or folder name without slashes."}
    end
  end

  defp sibling_path(path, name), do: child_path(Path.dirname(path), name)

  defp valid_child_name?(name) do
    name != "" and name not in [".", ".."] and not String.contains?(name, ["/", "\\"])
  end

  defp ensure_file_can_change(socket, path, action) do
    if socket.assigns.selected_file == path and socket.assigns.dirty? do
      {:error, "Save or discard changes before you #{action} this file."}
    else
      :ok
    end
  end

  defp ensure_not_root_folder(socket, path) do
    if Path.expand(path) == Path.expand(socket.assigns.cwd) do
      {:error, "The current workspace root cannot be deleted from the context menu."}
    else
      :ok
    end
  end

  defp path_within_root?(path, root_path) do
    relative_path = Path.relative_to(Path.expand(path), Path.expand(root_path))
    not String.starts_with?(relative_path, "..")
  end

  defp normalize_menu_coordinate(value) when is_integer(value), do: max(value, 0)

  defp normalize_menu_coordinate(value) when is_binary(value) do
    case Integer.parse(value) do
      {coordinate, _rest} -> max(coordinate, 0)
      :error -> 0
    end
  end

  defp normalize_menu_coordinate(_value), do: 0

  defp refresh_explorer(socket), do: assign(socket, :entries, load_entries(socket.assigns.cwd))

  defp replace_open_tab_path(socket, old_path, new_path) do
    open_tabs =
      Enum.map(socket.assigns.open_tabs, fn
        ^old_path -> new_path
        path -> path
      end)

    assign(socket, :open_tabs, open_tabs)
  end

  defp close_deleted_file(socket, path) do
    close_file_tab(socket, path)
  end

  defp format_reason(:eexist), do: "already exists"
  defp format_reason(:enotempty), do: "folder is not empty"
  defp format_reason(reason) when is_atom(reason), do: :file.format_error(reason)
  defp format_reason(reason), do: inspect(reason)

  defp format_delete_reason(reason) when reason in [:eexist, :enotempty],
    do: "folder is not empty"

  defp format_delete_reason(reason), do: format_reason(reason)

  defp add_open_tab(open_tabs, path) do
    if path in open_tabs do
      open_tabs
    else
      open_tabs ++ [path]
    end
  end

  defp close_file_tab(socket, path) do
    open_tabs = socket.assigns.open_tabs
    remaining_tabs = Enum.reject(open_tabs, &(&1 == path))

    cond do
      socket.assigns.selected_file != path ->
        assign(socket, :open_tabs, remaining_tabs)

      remaining_tabs == [] ->
        clear_editor(socket)

      true ->
        next_path = next_open_tab(open_tabs, remaining_tabs, path)

        case load_file_into_socket(assign(socket, :open_tabs, remaining_tabs), next_path) do
          {:ok, socket} -> socket
          {:error, message, socket} -> assign(socket, :error_message, message)
        end
    end
  end

  defp next_open_tab(open_tabs, remaining_tabs, closed_path) do
    closed_index = Enum.find_index(open_tabs, &(&1 == closed_path)) || 0
    next_index = min(closed_index, length(remaining_tabs) - 1)
    Enum.at(remaining_tabs, next_index)
  end

  defp file_tab_dom_id(path) do
    :crypto.hash(:sha256, path)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 12)
  end

  defp open_tab_label(path), do: Path.basename(path)

  defp related_file_paths(cwd, selected_path, content) do
    search_root = related_search_root(cwd, selected_path)

    selected_path
    |> Llm.ContextBuilder.related_file_paths_for_refactor(content, "", search_root)
    |> Enum.reject(&(&1 == selected_path))
  end

  defp related_file_label(_cwd, path), do: Path.basename(path)

  defp displayed_related_files(_selected_path, related_files, true)
       when is_list(related_files),
       do: related_files

  defp displayed_related_files(selected_path, related_files, false)
       when is_list(related_files) do
    Enum.filter(related_files, &strong_related_file?(selected_path, &1))
  end

  defp llm_related_files(%{
         assigns: %{
           selected_file: selected_file,
           related_files: related_files,
           related_file_context_overrides: overrides
         }
       })
       when is_binary(selected_file) and is_list(related_files) and is_map(overrides) do
    Enum.filter(related_files, &related_file_included?(selected_file, &1, overrides))
  end

  defp llm_related_files(%{assigns: %{related_files: related_files}}) when is_list(related_files) do
    related_files
  end

  defp llm_related_file_specs(%{
         assigns: %{
           selected_file: selected_file,
           related_files: related_files,
           related_file_context_overrides: overrides
         }
       })
       when is_binary(selected_file) and is_list(related_files) and is_map(overrides) do
    related_files
    |> Enum.filter(&related_file_included?(selected_file, &1, overrides))
    |> Enum.map(fn path ->
      %{
        path: path,
        relationship: related_file_reason(selected_file, path),
        included?: true,
        functions: related_file_public_contracts(path)
      }
    end)
  end

  defp llm_related_file_specs(_socket), do: []

  defp related_file_included?(socket, path) do
    related_file_included?(
      socket.assigns.selected_file,
      path,
      socket.assigns.related_file_context_overrides
    )
  end

  defp related_file_included?(selected_path, path, overrides)
       when is_binary(path) and is_map(overrides) do
    case Map.fetch(overrides, path) do
      {:ok, included?} -> included?
      :error -> strong_related_file?(selected_path, path)
    end
  end

  defp strong_related_file?(selected_path, path) do
    related_file_reason(selected_path, path) in ["uses", "used by", "uses/used by", "test/template"]
  end

  defp related_file_reason(nil, _path), do: "related"

  defp related_file_reason(selected_path, path)
       when is_binary(selected_path) and is_binary(path) do
    selected_analysis = file_analysis(selected_path)
    related_analysis = file_analysis(path)

    selected_uses_related? =
      Enum.any?(related_analysis.defined_modules, &(&1 in selected_analysis.referenced_modules))

    related_uses_selected? =
      Enum.any?(selected_analysis.defined_modules, &(&1 in related_analysis.referenced_modules))

    cond do
      selected_uses_related? and related_uses_selected? -> "uses/used by"
      selected_uses_related? -> "uses"
      related_uses_selected? -> "used by"
      convention_related_file?(selected_path, path) -> "test/template"
      true -> "related"
    end
  end

  defp file_analysis(path) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path) do
      Llm.ContextBuilder.analyze_file(content)
    else
      _ -> %{defined_modules: [], referenced_modules: [], public_functions: []}
    end
  end

  defp convention_related_file?(selected_path, path) do
    selected_basename = Path.basename(selected_path, Path.extname(selected_path))
    related_basename = Path.basename(path, Path.extname(path))

    related_basename in [
      selected_basename,
      "#{selected_basename}_test"
    ] or String.ends_with?(path, "/#{selected_basename}_test.exs")
  end

  defp related_file_functions(path) do
    path
    |> Llm.ContextBuilder.extract_function()
    |> Enum.map(fn function ->
      %{
        name: Map.get(function, :name, "[unknown]"),
        kind: Map.get(function, :kind, "def"),
        spec: Map.get(function, :spec),
        head: Map.get(function, :head, "[unknown]"),
        start_line: Map.get(function, :start_line, 1),
        end_line: Map.get(function, :end_line, 1)
      }
    end)
    |> Enum.reject(&(&1.name == "[unknown]"))
    |> Enum.uniq_by(&{&1.name, &1.start_line, &1.end_line})
    |> Enum.take(8)
  end

  defp related_file_public_contracts(path) do
    path
    |> related_file_functions()
    |> Enum.filter(&public_related_function?/1)
    |> Enum.map(fn function ->
      %{
        name: function.name,
        spec: function.spec,
        head: function.head,
        start_line: function.start_line,
        end_line: function.end_line
      }
    end)
  end

  defp public_related_function?(%{kind: kind}), do: kind in ["def", "defmacro", "defdelegate"]

  defp matching_file_paths(search_root, pattern) do
    case System.cmd("rg", ["-l", "--fixed-strings", pattern, search_root], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&Path.expand/1)
        |> Enum.filter(&File.regular?/1)
        |> Enum.take(12)

      {_output, _status} ->
        []
    end
  end

  defp related_search_root(cwd, selected_path) do
    umbrella_root_for_path(cwd) ||
      umbrella_root_for_path(selected_path) ||
      Path.expand(cwd)
  end

  defp umbrella_root_for_path(path) do
    expanded_path = Path.expand(path)
    parent_path = Path.dirname(expanded_path)

    cond do
      parent_path == expanded_path ->
        nil

      Path.basename(parent_path) == "apps" and
          File.exists?(Path.join(Path.dirname(parent_path), "mix.exs")) ->
        Path.dirname(parent_path)

      true ->
        umbrella_root_for_path(parent_path)
    end
  end

  defp build_llm_request(cwd, nil, _file_content, question) do
    messages = Llm.Prompts.editor_folder_question(cwd, question)
    prompt_stats = Llm.Prompts.stats(messages)

    llm_context = %{
      "mode" => "folder",
      "path" => cwd,
      "question" => question,
      "prompt_stats" => prompt_stats
    }

    {messages, llm_context}
  end

  defp build_llm_request(_cwd, selected_file, file_content, question) do
    messages = Llm.Prompts.editor_file_question(selected_file, file_content, question)
    prompt_stats = Llm.Prompts.stats(messages)

    llm_context = %{
      "mode" => "file",
      "path" => selected_file,
      "question" => question,
      "prompt_stats" => prompt_stats
    }

    {messages, llm_context}
  end

  defp llm_target_label(cwd, nil), do: "Folder: #{cwd}"
  defp llm_target_label(_cwd, selected_file), do: "File: #{selected_file}"

  defp llm_prompt_stats_label(%{"prompt_stats" => stats} = context) when is_map(stats) do
    estimated_tokens = map_value(stats, :estimated_tokens, 0)
    message_count = map_value(stats, :message_count, 0)

    parts =
      [
        "~#{estimated_tokens} #{pluralize(estimated_tokens, "token")}",
        "#{message_count} #{pluralize(message_count, "message")}"
      ] ++ file_count_stats_parts(context)

    "Prompt: " <> Enum.join(parts, " | ")
  end

  defp llm_prompt_stats_label(_context), do: nil

  defp file_count_stats_parts(context) do
    case Map.get(context, "file_count") do
      count when is_integer(count) ->
        ["#{count} #{pluralize(count, "file")}"]

      _ ->
        []
    end
  end

  defp map_value(map, key, default) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key)) || default
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  defp padding_left(depth), do: 8 + depth * @indent_px

  defp selected_file_label(nil), do: "No file selected"
  defp selected_file_label(path), do: Path.basename(path)

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
