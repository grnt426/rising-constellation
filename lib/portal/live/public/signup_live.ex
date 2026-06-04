defmodule Portal.SignupLive do
  use Portal, :live_view

  # Standalone /signup is retired: account creation is now invite-only and
  # the form lives on LandingLive (rendered when an ?invite=... param is
  # present). Keep the route alive so old bookmarks land on the right page.
  @impl true
  def mount(_params, _session, socket) do
    {:ok, push_navigate(socket, to: Routes.live_path(socket, Portal.LandingLive))}
  end
end
