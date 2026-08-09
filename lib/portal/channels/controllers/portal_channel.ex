defmodule Portal.Controllers.PortalChannel do
  use Phoenix.Channel

  alias RC.Instances

  # Public fan-out topic intentionally used for global announcements
  # (maintenance flag, min client version). Authenticated socket required
  # but no per-user binding — the payload is global and non-sensitive.
  # See Portal.Config / RC.Maintenance for the broadcast call sites.
  def join("portal:user:*", _data, socket) do
    # The topic has no join-time replay of broadcasts, so hand the client
    # the current deploy flag here — a client connecting mid-deploy would
    # otherwise never learn about it (the set-time broadcast predates its
    # join).
    {:ok, %{resp: "ok", deploy_flag: RC.Deploy.get_flag()}, socket}
  end

  def join("portal:user:" <> account_id, _data, socket) do
    with {id, ""} <- Integer.parse(account_id),
         true <- id == socket.assigns.account.id do
      {:ok, %{resp: "ok"}, socket}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def join("portal:profile:" <> profile_id, _data, socket) do
    if RC.Accounts.own_profile?(socket.assigns.account.id, profile_id) do
      {:ok, %{resp: "ok"}, socket}
    else
      {:error, :unauthorized}
    end
  end

  # `portal:instance:<iid>` is the topic used by handle_in("start", ...)
  # to spawn/restart an instance's supervisor tree. Without this gate any
  # authenticated socket could join `portal:instance:<any_iid>` and force-
  # start an instance owned by another user (admin gated only via the HTTP
  # path before — the channel bypassed it).
  def join("portal:instance:" <> instance_id, _data, socket) do
    account = socket.assigns.account

    with {iid, ""} <- Integer.parse(instance_id),
         true <- account.role == :admin or RC.Instances.own_instance?(account.id, iid) do
      {:ok, %{resp: "ok"}, assign(socket, instance_id: iid)}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  def handle_in("start", params, socket) do
    account_id = socket.assigns.account.id
    instance_id = socket.assigns.instance_id

    resp =
      case Instances.get_instance_with_registration(instance_id) do
        nil ->
          {:error, %{reason: "not_found"}}

        instance ->
          push(socket, "status", %{status: "step_0"})

          case instance.state do
            "open" ->
              do_fresh_start(instance, account_id)

            "not_running" ->
              do_restart(instance, account_id, confirm_fresh_start?(params))

            _other ->
              {:error, %{reason: "invalid_state"}}
          end
      end

    {:reply, resp, socket}
  end

  defp do_fresh_start(instance, account_id) do
    with {:ok, :instantiated} <- Instance.Manager.create_from_model(instance, nil, "portal:user:#{account_id}"),
         {:ok, :started, _} <- Instance.Manager.call(instance.id, :start),
         {:ok, %{registrations_errors: _}} <- Instances.start_instance(instance, account_id) do
      {:ok, %{resp: "Instance started"}}
    else
      {:error, error} -> {:error, %{reason: error}}
      _ -> {:error, %{reason: "general_error"}}
    end
  end

  defp do_restart(instance, account_id, confirm_fresh_start) do
    case Instances.restart_instance_from_snapshot(instance) do
      {:ok, :restarted} ->
        {:ok, _} = Instances.restart_instance(instance, account_id)
        {:ok, %{resp: "Instance restarted"}}

      {:error, :no_snapshot} when confirm_fresh_start ->
        do_fresh_restart(instance, account_id)

      {:error, :no_snapshot} ->
        # Signal to the frontend to confirm before wiping game progress.
        {:error, %{reason: "fresh_start_required"}}

      {:error, :load_failed} ->
        {:error, %{reason: "snapshot_load_failed"}}

      {:error, error} ->
        {:error, %{reason: error}}
    end
  end

  defp do_fresh_restart(instance, account_id) do
    with {:ok, :instantiated} <- Instance.Manager.create_from_model(instance, nil, "portal:user:#{account_id}"),
         {:ok, :started, _} <- Instance.Manager.call(instance.id, :start),
         {:ok, _} <- Instances.restart_instance(instance, account_id) do
      {:ok, %{resp: "Instance restarted", fresh_start: true}}
    else
      {:error, error} -> {:error, %{reason: error}}
      _ -> {:error, %{reason: "general_error"}}
    end
  end

  defp confirm_fresh_start?(%{"confirm_fresh_start" => v}) when v in [true, "true", 1, "1"], do: true
  defp confirm_fresh_start?(_), do: false

  def handle_in("read_conv", %{"cid" => cid}, socket) do
    "portal:profile:" <> profile_id = socket.topic
    pid = String.to_integer(profile_id)
    {:ok, last_seen} = Portal.MessengerController.update_last_seen(cid, pid)

    {:reply, {:ok, %{last_seen: last_seen}}, socket}
  end

  def handle_info(_, socket),
    do: {:noreply, socket}

  def broadcast_change(channel, payload) do
    Portal.Endpoint.broadcast(channel, "broadcast", payload)
  end
end
