defmodule EditorWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use EditorWeb, :controller
      use EditorWeb, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  @type quoted_helpers :: Macro.t()

  @spec static_paths() :: [String.t()]
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  @spec router() :: quoted_helpers()
  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  @spec channel() :: quoted_helpers()
  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  @spec controller() :: quoted_helpers()
  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: EditorWeb.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  @spec live_view() :: quoted_helpers()
  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  @spec live_component() :: quoted_helpers()
  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  @spec html() :: quoted_helpers()
  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: EditorWeb.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import EditorWeb.CoreComponents

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias EditorWeb.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  @spec verified_routes() :: quoted_helpers()
  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: EditorWeb.Endpoint,
        router: EditorWeb.Router,
        statics: EditorWeb.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  @spec __using__(atom()) :: quoted_helpers()
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
