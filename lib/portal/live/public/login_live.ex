defmodule Portal.LoginLive do
  use Portal, :live_view

  # Login itself is a classic form POST handled by Portal.LoginController —
  # password managers need a real submit-then-navigate sequence, which the
  # old phx-submit → WebSocket → data-attribute-echo → fetch chain never
  # produced (and it leaked the plaintext password into the DOM). This
  # LiveView only renders the page; the `login` JS hook still handles the
  # ?action=validate-registration&token=... email-link flow.
  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, csrf_token: Portal.LiveCsrf.html_form_token(socket))}
  end
end
