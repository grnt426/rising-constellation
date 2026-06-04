defmodule Portal.LandingLive do
  use Portal, :live_view

  alias RC.Accounts
  alias RC.Accounts.InviteToken

  require Logger

  @impl true
  def mount(params, _session, socket) do
    {invite_state, invite_token} = resolve_invite(Map.get(params, "invite"))

    socket =
      socket
      |> assign(:show_login, false)
      |> assign(:validated, false)
      |> assign(:email, nil)
      |> assign(:password, nil)
      |> assign(:invite_state, invite_state)
      |> assign(:invite_token, invite_token)

    {:ok, socket}
  end

  @impl true
  def handle_event("login", %{"account" => account}, socket) do
    login_mode = Portal.Config.fetch_key(:login_mode)
    email = Map.get(account, "email")
    password = Map.get(account, "password")

    case Accounts.get_account_by_email_and_password(email, password) do
      {:ok, account} ->
        if login_mode == :disabled and account.role != :admin do
          {:noreply, put_flash(socket, :error, :connection_disabled)}
        else
          socket =
            socket
            |> assign(validated: true)
            |> assign(email: email)
            |> assign(password: password)

          {:noreply, socket}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The email address is unknown or the password is wrong.")}
    end
  end

  @impl true
  def handle_event("show_login", _value, socket) do
    {:noreply, assign(socket, :show_login, true)}
  end

  @impl true
  def handle_event("show_signup", _value, socket) do
    {:noreply, assign(socket, :show_login, false)}
  end

  # Three-way result so the template can render distinct messages:
  #   :none    -- no `?invite=` in the URL; show the invite-only landing copy
  #   :valid   -- decrypted cleanly; show the signup form, embed the raw token
  #   :expired -- past the 24h window; tell the user to ask for a fresh one
  #   :invalid -- ciphertext rejected; same UX as expired but distinct log line
  defp resolve_invite(nil), do: {:none, nil}
  defp resolve_invite(""), do: {:none, nil}

  defp resolve_invite(token) when is_binary(token) do
    case InviteToken.decode(Portal.Endpoint, token) do
      {:ok, _referrer_id} -> {:valid, token}
      {:error, :expired} -> {:expired, nil}
      {:error, _} -> {:invalid, nil}
    end
  end

  defp resolve_invite(_), do: {:invalid, nil}
end
