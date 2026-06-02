defmodule RcBot.Web.ErrorHTML do
  @moduledoc false
  use RcBot.Web, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
