defmodule EditorWeb.Layouts do
  @moduledoc """
  Layout components and shared application shell primitives.
  """

  use EditorWeb, :html

  embed_templates "layouts/*"

  @type assigns :: map()
  @type rendered :: Phoenix.LiveView.Rendered.t()

  @doc """
  Renders the application shell around page content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :content_class, :string,
    default: "mx-auto w-full max-w-7xl px-4 py-6 sm:px-6 lg:px-8",
    doc: "optional class override for the main content container"

  slot :inner_block, required: true

  @spec app(assigns()) :: rendered()
  def app(assigns) do
    ~H"""
    <main id="app-content" class="flex min-h-screen w-full">
      {render_slot(@inner_block)}
    </main>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  @spec flash_group(assigns()) :: rendered()
  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.
  """
  @spec theme_toggle(assigns()) :: rendered()
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex items-center rounded-full border border-base-300 bg-base-200 p-1">
      <div class="pointer-events-none absolute inset-y-1 left-1 w-[calc(33.333%-0.25rem)] rounded-full bg-base-100 shadow-sm transition-[left] [[data-theme=light]_&]:left-[calc(33.333%+0.125rem)] [[data-theme=dark]_&]:left-[calc(66.666%+0.125rem)]" />

      <.theme_option theme="system" icon="hero-computer-desktop" label="System" />
      <.theme_option theme="light" icon="hero-sun" label="Light" />
      <.theme_option theme="dark" icon="hero-moon" label="Dark" />
    </div>
    """
  end

  attr :theme, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp theme_option(assigns) do
    ~H"""
    <button
      type="button"
      class="relative z-10 flex w-10 items-center justify-center rounded-full p-2 text-base-content/75 transition hover:text-base-content"
      phx-click={JS.dispatch("phx:set-theme")}
      data-phx-theme={@theme}
      aria-label={@label}
      title={@label}
    >
      <.icon name={@icon} class="size-4" />
    </button>
    """
  end
end
