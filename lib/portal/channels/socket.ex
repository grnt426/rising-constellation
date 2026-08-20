defmodule Portal.Socket do
  use Phoenix.Socket

  # Channels
  channel("portal:*", Portal.Controllers.PortalChannel)
  channel("instance:global:*", Portal.Controllers.GlobalChannel)
  channel("instance:faction:*", Portal.Controllers.FactionChannel)
  channel("instance:player:*", Portal.Controllers.PlayerChannel)
  channel("cheat:player:*", Portal.Controllers.CheatChannel)

  @impl true
  def connect(%{"token" => token}, socket) do
    case Guardian.Phoenix.Socket.authenticate(socket, RC.Guardian, token) do
      {:ok, socket} ->
        %RC.Accounts.Account{} = account = socket.assigns.guardian_default_resource

        # Deletion-pending accounts are locked out of the game socket too —
        # the lockout page runs on plain HTTP (see Portal.Plug.DeletionLock).
        if account.deletion_requested_at do
          :error
        else
          {:ok, assign(socket, :account, %{id: account.id, role: account.role, is_bot: account.is_bot})}
        end

      {:error, _} ->
        :error
    end
  end

  @impl true
  def connect(_params, _socket), do: :error

  @impl true
  def id(_socket), do: nil

  @doc """
  Util function to garbage collect the transport process, use it after processing large messages:
  https://hexdocs.pm/phoenix/Phoenix.Socket.html#module-garbage-collection
  """
  def gc(socket, wait \\ 5_000) do
    # Stage 7 F25: supervised under RC.TaskSupervisor (previously a
    # raw Task.start orphan). :temporary so a crash isn't restarted.
    Task.Supervisor.start_child(
      RC.TaskSupervisor,
      fn ->
        Process.sleep(wait)
        send(socket.transport_pid, :garbage_collect)
      end,
      restart: :temporary
    )
  end

end
