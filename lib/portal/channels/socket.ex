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
        %{id: id, role: role, is_bot: is_bot} = account_from_socket(socket)

        {:ok, assign(socket, :account, %{id: id, role: role, is_bot: is_bot})}

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

  defp account_from_socket(socket) do
    %{guardian_default_resource: %RC.Accounts.Account{} = account} = socket.assigns
    %{id: account.id, role: account.role, is_bot: account.is_bot}
  end
end
