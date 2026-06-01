defmodule Portal.Controllers.FactionChannel do
  use Phoenix.Channel
  use Portal.ReplayRecorder

  alias Portal.Presence
  alias Instance.Galaxy.Galaxy

  def topic(%{instance_id: instance_id, faction_id: faction_id}) do
    "instance:faction:#{instance_id}:#{faction_id}"
  end

  def join("instance:faction:" <> channel_data, %{"registration" => registration_token}, socket) do
    [instance_id, faction_id] =
      channel_data
      |> String.split(":")
      |> Enum.map(&String.to_integer/1)

    if Instance.Manager.created?(instance_id) do
      {:ok, galaxy} = Game.call(instance_id, :galaxy, :master, :get_state)
      {:ok, time} = Game.call(instance_id, :time, :master, :get_state)

      has_replay =
        not (time.speed == :fast or Galaxy.is_tutorial(galaxy) or Application.get_env(:rc, :environment) == :test)

      {profile_id, registration} =
        if Galaxy.is_tutorial(galaxy) do
          # Tutorial: bind to the caller's owned profile. The synthetic
          # registration carries faction_id=1 (the player's faction in
          # `tutorial_data`) so the standard faction_id == faction_id
          # check below works without a tutorial short-circuit.
          if RC.Accounts.own_profile?(socket.assigns.account.id, galaxy.tutorial_id) do
            {galaxy.tutorial_id, %{faction_id: 1}}
          else
            {false, nil}
          end
        else
          case RC.Registrations.valid?(instance_id, registration_token, socket.assigns.account.id) do
            {:ok, registration} -> {registration.profile_id, registration}
            {:error, _} -> {false, nil}
          end
        end

      if profile_id do
        # Removed the previous `Galaxy.is_tutorial(galaxy) or ...` short-
        # circuit — the tutorial branch above supplies a registration with
        # the expected faction_id, so this is now an honest equality test.
        if registration.faction_id == faction_id do
          send(self(), :after_join)

          # assign ids to socket
          socket =
            socket
            |> assign(:instance_id, instance_id)
            |> assign(:faction_id, faction_id)
            |> assign(:player_id, profile_id)
            |> assign(:channel_name, "faction")
            |> assign(:is_tutorial, Galaxy.is_tutorial(galaxy))
            |> assign(:has_replay, has_replay)

          {:ok, faction} = Game.call(instance_id, :faction, faction_id, :get_state)
          Portal.Socket.gc(socket)
          {:ok, %{faction_faction: faction}, socket}
        else
          {:error, %{reason: "invalid_registration (faction id doesn't match)"}}
        end
      else
        {:error, %{reason: "invalid_registration"}}
      end
    else
      {:error, %{reason: "instance_not_found"}}
    end
  end

  def handle_info(:after_join, socket) do
    {:ok, _} = Presence.track(socket, socket.assigns.player_id, %{})
    push(socket, "presence_state", Presence.list(socket))

    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  record("get_system", %{"system_id" => system_id}, socket) do
    query = {:get_system_state, system_id}
    system_with_visibility = Game.call(socket.assigns.instance_id, :faction, socket.assigns.faction_id, query)

    {:ok, %{system: system_with_visibility}}
  end

  record("get_character", %{"character_id" => character_id}, socket) do
    query = {:get_character_state, character_id}
    character_with_visibility = Game.call(socket.assigns.instance_id, :faction, socket.assigns.faction_id, query)

    {:ok, %{character: character_with_visibility}}
  end

  # Stage 4 #C1 + #H8 fix.
  #
  # Before: `from` was taken from the client payload and `message` was not
  # type-checked. The agent's downstream `String.length(message)` raised on
  # non-binary input, crashing the per-faction GenServer (DoS for every
  # member). `from` was rendered as authoritative author, enabling
  # impersonation of any player, "GameMaster", admin announcements, etc.
  #
  # After: `from` is derived server-side from `socket.assigns.player_id`
  # (which Stage 3 #1 already binds to the JWT-authenticated account). The
  # `message` is validated as a binary; non-string payloads are rejected
  # with a clean error instead of crashing the Faction.Agent.
  record("push_chat_message", %{"message" => message}, socket) do
    if is_binary(message) do
      Game.cast(
        socket.assigns.instance_id,
        :faction,
        socket.assigns.faction_id,
        {:push_message, socket.assigns.player_id, message}
      )

      :ok
    else
      {:error, %{reason: :invalid_payload}}
    end
  end

  # Stage 4 #C1 fix (send_resources). Validate the `resources` map at the
  # channel boundary: only well-formed, non-negative numeric entries for
  # the three resource keys are forwarded to the agent. Anything else
  # would have caused a Faction.Agent crash inside Market.send_resources.
  record(
    "send_resources",
    %{"player_id" => to_player_id, "resources" => resources},
    socket
  ) do
    cond do
      not is_integer(to_player_id) ->
        {:error, %{reason: :invalid_player_id}}

      not is_map(resources) ->
        {:error, %{reason: :invalid_resources}}

      not valid_resources_map?(resources) ->
        {:error, %{reason: :invalid_resources}}

      true ->
        case Game.call(
               socket.assigns.instance_id,
               :faction,
               socket.assigns.faction_id,
               {:send_resources, socket.assigns.player_id, to_player_id, resources}
             ) do
          {:error, reason} -> {:error, %{reason: reason}}
          _ -> :ok
        end
    end
  end

  # Only "credit" / "technology" / "ideology" allowed; values must be
  # non-negative integers. Extra keys silently ignored (Market.send_resources
  # only reads these three names) but invalid TYPES would crash the agent
  # — so reject the whole call.
  defp valid_resources_map?(resources) do
    Enum.all?(["credit", "technology", "ideology"], fn k ->
      case Map.get(resources, k, 0) do
        n when is_integer(n) and n >= 0 -> true
        _ -> false
      end
    end)
  end

  def broadcast_change(channel, payload) do
    Portal.Endpoint.broadcast(channel, "broadcast", payload)
  end
end
