defmodule RcBot.Web do
  @moduledoc """
  Web-layer module imports. Used as `use RcBot.Web, :live_view` etc.
  """

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {RcBot.Web.Layouts, :root}
      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
