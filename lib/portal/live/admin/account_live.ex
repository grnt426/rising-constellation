defmodule Portal.AccountLive do
  use Portal, :admin_live_view

  alias RC.Accounts
  alias RC.Accounts.Account
  alias RC.Accounts.Profile
  alias RC.Groups
  alias RC.Groups.Group
  alias RC.Logs

  @impl true
  def handle_params(params, _, socket) do
    account = Accounts.get_account_preload(Map.get(params, "uid"))

    if account != nil do
      {:noreply, assign(socket, account: account)}
    else
      IO.inspect("account not found")
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update", params, socket) do
    # Stage 6 Cluster B fix. Was: raw `params` straight into
    # `Accounts.update_account` → full `Account.changeset` → casts
    # role/password/email/steam_id. A demoted-but-still-connected
    # admin (Stage 2 #11) could promote themselves and rewrite peer
    # admins' credentials with a single WebSocket frame.
    #
    # `admin_update_account/3` rejects peer-admin operations with
    # `:cannot_modify_peer_admin` and uses `changeset_admin/2` which
    # omits `:password` (admins must use the password-reset flow) and
    # `:steam_id` (Steam binding goes through SteamController).
    actor = socket.assigns.current_user
    account = Accounts.get_account(socket.assigns.account.id)

    if account.role == :admin,
      do: Logs.create_log(%{action: :update}, account),
      else: Logs.create_log(%{action: :update_restricted}, account)

    case Accounts.admin_update_account(account, params, actor) do
      {:ok, account} ->
        account = Accounts.get_account_preload(account.id)
        {:noreply, assign(socket, account: account)}

      {:error, :cannot_modify_peer_admin} ->
        {:noreply, put_flash(socket, :error, "cannot modify another admin's account")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "account update failed")}
    end
  end

  @impl true
  def handle_event("toggle_is_bot", _params, socket) do
    actor = socket.assigns.current_user
    account = Accounts.get_account(socket.assigns.account.id)

    Logs.create_log(%{action: :update_restricted}, account)

    case Accounts.admin_update_account(account, %{"is_bot" => not account.is_bot}, actor) do
      {:ok, _} ->
        account = Accounts.get_account_preload(socket.assigns.account.id)

        # Mirror onto the bot's profile(s) so the denormalized field stays
        # in sync — rankings, search, and the dashboard read profile.is_bot.
        profiles = Accounts.list_profiles_by_account(%{}, account.id)

        profiles =
          case profiles do
            {:ok, %{entries: entries}} -> entries
            _ -> []
          end

        Enum.each(profiles, fn p ->
          p
          |> Ecto.Changeset.change(%{is_bot: account.is_bot})
          |> RC.Repo.update()
        end)

        {:noreply,
         socket
         |> assign(:account, account)
         |> put_flash(:info, "Bot flag toggled to #{account.is_bot}")}

      {:error, :cannot_modify_peer_admin} ->
        {:noreply, put_flash(socket, :error, "cannot modify another admin's account")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "is_bot toggle failed")}
    end
  end

  @impl true
  def handle_event("bind_group", %{"group" => group}, socket) do
    with %Account{} = account <- Accounts.get_account(socket.assigns.account.id),
         %Group{} = group <- Groups.get_group(group["id"]) do
      if account.role == :admin,
        do: Logs.create_log(%{action: :update}, account),
        else: Logs.create_log(%{action: :update_restricted}, account)

      Groups.insert_accounts(group, [account.id])

      account = Accounts.get_account_preload(account.id)
      {:noreply, assign(socket, account: account)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("add_money", %{"money" => %{"amount" => amount}}, socket) do
    account = Accounts.get_account(socket.assigns.account.id)

    if account do
      case Integer.parse(amount) do
        {amount, _} ->
          Ecto.Multi.new()
          |> Accounts.update_account_money(account, amount, "update_admin")
          |> RC.Repo.transaction()

          account = Accounts.get_account_preload(account.id)
          {:noreply, assign(socket, account: account)}

        :error ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("unbind_group", %{"gid" => gid}, socket) do
    with %Account{} = account <- Accounts.get_account(socket.assigns.account.id),
         %Group{} = group <- Groups.get_group(gid) do
      if account.role == :admin,
        do: Logs.create_log(%{action: :update}, account),
        else: Logs.create_log(%{action: :update_restricted}, account)

      Groups.remove_account(group, account.id)

      account = Accounts.get_account_preload(account.id)
      {:noreply, assign(socket, account: account)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("resign", %{"pid" => pid}, socket) do
    with {:ok, resp} <- Accounts.list_profiles_by_account(%{}, socket.assigns.account.id),
         %Profile{} = profile <- Enum.find(resp.entries, fn p -> p.id == String.to_integer(pid) end) do
      registrations_to_resign =
        profile.registrations
        |> Enum.filter(fn r -> not Enum.member?(["created", "ended"], r.faction.instance.state) end)

      Enum.each(registrations_to_resign, fn r ->
        RC.Instances.resign_player(r.faction.id, pid)
      end)

      if Enum.empty?(registrations_to_resign) do
        {:noreply, socket}
      else
        account = Accounts.get_account_preload(socket.assigns.account.id)
        {:noreply, assign(socket, account: account)}
      end
    else
      _ ->
        {:noreply, socket}
    end
  end
end
