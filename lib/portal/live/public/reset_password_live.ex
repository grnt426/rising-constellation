defmodule Portal.ResetPasswordLive do
  use Portal, :live_view

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Choose a new password")}
end
